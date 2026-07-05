import { spawn } from "node:child_process";
import { mkdir, mkdtemp, rm, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { mediaPath, readProject } from "./projects";
import { hasStream, num, round } from "./util";

/** The audible slice of the cut, in timeline time (mirrors ExportSpec). */
export interface TranscribeSpec {
  projectId: string;
  duration: number;
  locale?: string;
  clips: { file: string; in: number; out: number; muted: boolean }[];
  audio: { file: string; in: number; out: number; start: number; volume: number }[];
}

interface Word {
  t0: number;
  t1: number;
  w: string;
}

export interface Cue {
  id: string;
  start: number;
  end: number;
  text: string;
  words: Word[];
}

export interface TranscribeJob {
  id: string;
  projectId: string;
  status: "running" | "done" | "error";
  stage: "audio" | "model" | "transcribe";
  error?: string;
  cues?: Cue[];
}

// Survives dev-server module reloads (same trick as export jobs).
const g = globalThis as unknown as { __veditorSttJobs?: Map<string, TranscribeJob> };
const jobs = (g.__veditorSttJobs ??= new Map<string, TranscribeJob>());

export function getTranscribeJob(id: string) {
  return jobs.get(id);
}

function run(cmd: string, args: string[], notFound?: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const p = spawn(cmd, args);
    let out = "";
    let err = "";
    p.stdout.on("data", (d) => (out += d));
    p.stderr.on("data", (d) => (err += d));
    p.on("error", (e) =>
      reject(e.message.includes("ENOENT") && notFound ? new Error(notFound) : e)
    );
    p.on("close", (code) => {
      if (code === 0) resolve(out);
      else reject(new Error(err.trim().split("\n").slice(-4).join("\n") || `${cmd} exited ${code}`));
    });
  });
}

/**
 * The speech engine: Apple's on-device SpeechAnalyzer (macOS 26+), wrapped by
 * a tiny Swift CLI compiled on first use into ~/.cache/cut. Nothing ever
 * leaves the machine.
 */
async function ensureStt(): Promise<string> {
  const src = path.join(process.cwd(), "src", "cut", "server", "native", "cut-stt.swift");
  const bin = path.join(os.homedir(), ".cache", "cut", "cut-stt");
  const [b, s] = await Promise.all([stat(bin).catch(() => null), stat(src)]);
  if (b?.isFile() && b.mtimeMs >= s.mtimeMs) return bin;
  await mkdir(path.dirname(bin), { recursive: true });
  await run(
    "swiftc",
    ["-O", "-parse-as-library", src, "-o", bin],
    "Swift compiler not found. Install the Xcode Command Line Tools: xcode-select --install"
  ).catch((e: Error) => {
    throw new Error(`Could not build the on-device speech engine (needs macOS 26+).\n${e.message}`);
  });
  return bin;
}

/** Group word timings into short caption-sized cues (CapCut/Opus style). */
export function groupWords(words: Word[]): Cue[] {
  const MAX_CHARS = 38;
  const MAX_DUR = 3.5;
  const GAP = 0.6;
  const cues: Cue[] = [];
  let cur: Word[] = [];
  const flush = () => {
    if (cur.length === 0) return;
    const start = round(cur[0].t0);
    cues.push({
      id: crypto.randomUUID().slice(0, 8),
      start,
      end: round(Math.max(cur[cur.length - 1].t1, start + 0.3)),
      text: cur.map((w) => w.w).join(" "),
      words: cur.map((w) => ({ t0: round(w.t0), t1: round(w.t1), w: w.w })),
    });
    cur = [];
  };
  for (const w of words) {
    if (cur.length > 0) {
      const last = cur[cur.length - 1];
      const chars = cur.reduce((n, x) => n + x.w.length + 1, 0) + w.w.length;
      if (
        w.t0 - last.t1 > GAP ||
        chars > MAX_CHARS ||
        w.t1 - cur[0].t0 > MAX_DUR ||
        /[.!?…]$/.test(last.w)
      )
        flush();
    }
    cur.push(w);
  }
  flush();
  return cues;
}

export async function createTranscribeJob(spec: TranscribeSpec): Promise<TranscribeJob> {
  const job: TranscribeJob = {
    id: crypto.randomUUID().slice(0, 12),
    projectId: spec.projectId,
    status: "running",
    stage: "audio",
  };
  jobs.set(job.id, job);
  void runTranscribe(job, spec).catch((err: unknown) => {
    job.status = "error";
    job.error = err instanceof Error ? err.message : String(err);
  });
  return job;
}

async function runTranscribe(job: TranscribeJob, spec: TranscribeSpec) {
  if (!(await readProject(spec.projectId))) throw new Error("Project not found.");
  if (spec.clips.length === 0) throw new Error("Add a video to the timeline first.");

  const tmpDir = await mkdtemp(path.join(os.tmpdir(), "veditor-stt-"));
  try {
    // Render the cut's audible mix (clip audio + soundtrack, in timeline
    // time) to a 16 kHz mono wav — the same graph the export uses, minus
    // video, so cue times line up with the timeline exactly.
    const files = [...new Set([...spec.clips, ...spec.audio].map((c) => c.file))];
    const inputs: string[] = [];
    const inputIndex = new Map<string, number>();
    const audible = new Map<string, boolean>();
    const paths = files.map((f) => mediaPath(spec.projectId, f));
    await Promise.all(
      paths.map(async (p, i) => {
        if (!(await stat(p).catch(() => null)))
          throw new Error(`Media file missing: ${files[i]}`);
      })
    );
    files.forEach((f, i) => {
      inputIndex.set(f, inputs.length / 2);
      inputs.push("-i", paths[i]);
    });
    await Promise.all(
      files.map(async (f, i) => audible.set(f, await hasStream(paths[i], "a")))
    );

    const hasSpeechSource =
      spec.clips.some((c) => !c.muted && audible.get(c.file)) ||
      spec.audio.some((a) => audible.get(a.file));
    if (!hasSpeechSource) {
      job.cues = [];
      job.status = "done";
      return;
    }

    const filters: string[] = [];
    spec.clips.forEach((c, j) => {
      const dur = Math.max(0.1, c.out - c.in);
      if (!c.muted && audible.get(c.file)) {
        filters.push(
          `[${inputIndex.get(c.file)}:a]atrim=${num(c.in)}:${num(c.out)},asetpts=PTS-STARTPTS,` +
            `aresample=16000,aformat=sample_fmts=s16:channel_layouts=mono,` +
            `apad=whole_dur=${num(dur)},atrim=0:${num(dur)}[a${j}]`
        );
      } else {
        filters.push(`anullsrc=r=16000:cl=mono,atrim=0:${num(dur)},asetpts=PTS-STARTPTS[a${j}]`);
      }
    });
    filters.push(
      spec.clips.map((_, j) => `[a${j}]`).join("") + `concat=n=${spec.clips.length}:v=0:a=1[acat]`
    );

    const soundLabels: string[] = [];
    spec.audio.forEach((a, k) => {
      if (!audible.get(a.file)) return;
      filters.push(
        `[${inputIndex.get(a.file)}:a]atrim=${num(a.in)}:${num(a.out)},asetpts=PTS-STARTPTS,` +
          `aresample=16000,aformat=sample_fmts=s16:channel_layouts=mono,` +
          `volume=${num(a.volume)},adelay=${Math.max(0, Math.round(a.start * 1000))}:all=1[snd${k}]`
      );
      soundLabels.push(`snd${k}`);
    });
    let aLabel = "acat";
    if (soundLabels.length > 0) {
      filters.push(
        ["acat", ...soundLabels].map((l) => `[${l}]`).join("") +
          `amix=inputs=${soundLabels.length + 1}:duration=first:dropout_transition=0:normalize=0[amix]`
      );
      aLabel = "amix";
    }

    const wav = path.join(tmpDir, "mix.wav");
    await run(
      "ffmpeg",
      [
        "-y",
        ...inputs,
        "-filter_complex", filters.join(";"),
        "-map", `[${aLabel}]`,
        "-ac", "1",
        "-ar", "16000",
        "-t", num(spec.duration),
        wav,
      ],
      "ffmpeg was not found. Install it with: brew install ffmpeg"
    );

    job.stage = "model";
    const bin = await ensureStt();

    job.stage = "transcribe";
    const out = await run(bin, [wav, spec.locale ?? "en-US"]);
    const parsed = JSON.parse(out) as { words: Word[] };
    // Clamp to the cut and drop anything degenerate the model emits.
    const words = parsed.words
      .filter((w) => w.w.trim().length > 0 && w.t1 > w.t0 - 0.001)
      .map((w) => ({
        t0: Math.max(0, Math.min(w.t0, spec.duration)),
        t1: Math.max(0, Math.min(w.t1, spec.duration)),
        w: w.w.trim(),
      }))
      .filter((w) => w.t1 > w.t0);

    job.cues = groupWords(words);
    job.status = "done";
  } finally {
    void rm(tmpDir, { recursive: true, force: true });
  }
}
