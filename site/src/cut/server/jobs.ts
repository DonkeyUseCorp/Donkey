import { spawn, type ChildProcess } from "node:child_process";
import { mkdir, mkdtemp, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assertLocalRuntime } from "./local-only";
import { exportsDir, mediaPath, readProject } from "./projects";
import { hasStream, num } from "./util";

export interface ExportSpec {
  projectId: string;
  width: number;
  height: number;
  fps: number;
  crf: number;
  preset: string;
  duration: number;
  clips: {
    file: string;
    in: number;
    out: number;
    muted: boolean;
    /** "fit" letterboxes (default); "fill" covers the frame and crops. */
    fit?: "fit" | "fill";
    panX?: number; // crop-window pan -1..1 (fill mode)
    panY?: number;
  }[];
  audio: {
    file: string;
    in: number;
    out: number;
    start: number;
    volume: number;
    fadeIn?: number;
    fadeOut?: number;
  }[];
  overlays: { file: string; start: number; end: number }[];
}

export interface Job {
  id: string;
  status: "running" | "done" | "error";
  progress: number; // 0..1
  error?: string;
  tmpDir: string;
  outPath: string;
  outName: string;
  proc?: ChildProcess;
  log: string[];
}

// Survives dev-server module reloads.
const g = globalThis as unknown as { __veditorJobs?: Map<string, Job> };
const jobs = (g.__veditorJobs ??= new Map<string, Job>());

export function getJob(id: string) {
  return jobs.get(id);
}

export function cancelJob(id: string) {
  const job = jobs.get(id);
  if (job?.proc && job.status === "running") {
    job.proc.kill("SIGKILL");
    job.status = "error";
    job.error = "Export canceled.";
  }
}

function stamp() {
  const d = new Date();
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}

export async function createJob(form: FormData): Promise<Job> {
  assertLocalRuntime();
  const spec = JSON.parse(String(form.get("spec"))) as ExportSpec;
  const tmpDir = await mkdtemp(path.join(os.tmpdir(), "veditor-"));
  const id = crypto.randomUUID().slice(0, 12);
  const outDir = exportsDir(spec.projectId);
  await mkdir(outDir, { recursive: true });
  // Include the unique job id so two exports in the same second can't collide
  // on the same output path (which would clobber the first render).
  const outName = `export-${stamp()}-${id}.mp4`;
  const job: Job = {
    id,
    status: "running",
    progress: 0,
    tmpDir,
    outPath: path.join(outDir, outName),
    outName,
    log: [],
  };
  jobs.set(id, job);

  try {
    if (!(await readProject(spec.projectId))) throw new Error("Project not found.");
    // Overlay PNGs are rendered in the browser and uploaded with the spec.
    for (const [key, value] of form.entries()) {
      if (value instanceof File && key !== "spec") {
        await writeFile(path.join(tmpDir, path.basename(key)), Buffer.from(await value.arrayBuffer()));
      }
    }
    void runExport(job, spec).catch((err: unknown) => {
      job.status = "error";
      job.error = err instanceof Error ? err.message : String(err);
      void rm(job.outPath, { force: true }); // no half-written files in exports/
    });
  } catch (err) {
    job.status = "error";
    job.error = err instanceof Error ? err.message : String(err);
  }
  return job;
}

async function resolveMedia(spec: ExportSpec, file: string) {
  const p = mediaPath(spec.projectId, file);
  const info = await stat(p).catch(() => null);
  if (!info?.isFile()) throw new Error(`Media file missing from project: ${file}`);
  return p;
}

async function runExport(job: Job, spec: ExportSpec) {
  if (spec.clips.length === 0) throw new Error("Nothing to export.");
  const { width: W, height: H, fps } = spec;

  // One ffmpeg input per distinct media file (from the project folder),
  // plus one per uploaded overlay PNG.
  const mediaFiles = [
    ...new Set([...spec.clips, ...spec.audio].map((c) => c.file)),
  ];
  const audioPresence = new Map<string, boolean>();
  const videoPresence = new Map<string, boolean>();
  const inputs: string[] = [];
  const inputIndex = new Map<string, number>();
  // Resolve paths in order first so ffmpeg input indices stay deterministic,
  // then probe every file's streams concurrently.
  const paths = await Promise.all(mediaFiles.map((f) => resolveMedia(spec, f)));
  mediaFiles.forEach((f, i) => {
    inputIndex.set(f, inputs.length / 2);
    inputs.push("-i", paths[i]);
  });
  await Promise.all(
    mediaFiles.map(async (f, i) => {
      audioPresence.set(f, await hasStream(paths[i], "a"));
      // If the video probe itself fails, assume the clip HAS video rather than
      // silently replacing it with black frames — a normal .mp4 must never
      // export as a black screen just because one ffprobe hiccupped.
      let probeFailed = false;
      const hasVideo = await hasStream(paths[i], "v", () => (probeFailed = true));
      videoPresence.set(f, hasVideo || probeFailed);
    })
  );
  for (const o of spec.overlays) {
    inputIndex.set(o.file, inputs.length / 2);
    inputs.push("-i", path.join(job.tmpDir, path.basename(o.file)));
  }

  const filters: string[] = [];

  // Per-clip normalized video + audio segments for concat.
  spec.clips.forEach((c, j) => {
    const idx = inputIndex.get(c.file)!;
    const dur = Math.max(0.1, c.out - c.in);
    if (videoPresence.get(c.file)) {
      const frame =
        c.fit === "fill"
          ? // Cover the frame, then crop; the pan chooses the visible window.
            `scale=${W}:${H}:force_original_aspect_ratio=increase,` +
            `crop=${W}:${H}:(iw-ow)*${num(0.5 + Math.max(-1, Math.min(1, c.panX ?? 0)) / 2)}` +
            `:(ih-oh)*${num(0.5 + Math.max(-1, Math.min(1, c.panY ?? 0)) / 2)}`
          : `scale=${W}:${H}:force_original_aspect_ratio=decrease,` +
            `pad=${W}:${H}:(ow-iw)/2:(oh-ih)/2:color=black`;
      filters.push(
        `[${idx}:v]trim=${num(c.in)}:${num(c.out)},setpts=PTS-STARTPTS,` +
          `fps=${fps},${frame},setsar=1,format=yuv420p[v${j}]`
      );
    } else {
      // No video stream in this file: keep the cut alive with black frames.
      filters.push(
        `color=c=black:s=${W}x${H}:r=${fps},trim=0:${num(dur)},setpts=PTS-STARTPTS,format=yuv420p[v${j}]`
      );
    }
    if (!c.muted && audioPresence.get(c.file)) {
      filters.push(
        `[${idx}:a]atrim=${num(c.in)}:${num(c.out)},asetpts=PTS-STARTPTS,` +
          `aresample=44100,aformat=sample_fmts=fltp:channel_layouts=stereo,` +
          `apad=whole_dur=${num(dur)},atrim=0:${num(dur)}[a${j}]`
      );
    } else {
      filters.push(
        `anullsrc=r=44100:cl=stereo,atrim=0:${num(dur)},asetpts=PTS-STARTPTS[a${j}]`
      );
    }
  });

  const concatIn = spec.clips.map((_, j) => `[v${j}][a${j}]`).join("");
  filters.push(`${concatIn}concat=n=${spec.clips.length}:v=1:a=1[vcat][acat]`);

  // Burn in text overlays, each windowed to its timeline range.
  let vLabel = "vcat";
  spec.overlays.forEach((o, k) => {
    const idx = inputIndex.get(o.file)!;
    const next = `vov${k}`;
    filters.push(
      `[${vLabel}][${idx}:v]overlay=0:0:enable='between(t,${num(o.start)},${num(o.end)})'[${next}]`
    );
    vLabel = next;
  });

  // Soundtrack clips: trim, gain, shift into place, mix with clip audio.
  const soundLabels: string[] = [];
  spec.audio.forEach((a, k) => {
    const idx = inputIndex.get(a.file)!;
    if (!audioPresence.get(a.file)) return;
    const delayMs = Math.max(0, Math.round(a.start * 1000));
    const len = Math.max(0.1, a.out - a.in);
    const fades: string[] = [];
    if (a.fadeIn && a.fadeIn > 0.01) fades.push(`afade=t=in:st=0:d=${num(a.fadeIn)}`);
    if (a.fadeOut && a.fadeOut > 0.01)
      fades.push(`afade=t=out:st=${num(Math.max(0, len - a.fadeOut))}:d=${num(a.fadeOut)}`);
    filters.push(
      `[${idx}:a]atrim=${num(a.in)}:${num(a.out)},asetpts=PTS-STARTPTS,` +
        `aresample=44100,aformat=sample_fmts=fltp:channel_layouts=stereo,` +
        `volume=${num(a.volume)},` +
        (fades.length ? fades.join(",") + "," : "") +
        `adelay=${delayMs}:all=1[snd${k}]`
    );
    soundLabels.push(`snd${k}`);
  });

  let aLabel = "acat";
  if (soundLabels.length > 0) {
    const mixIn = ["acat", ...soundLabels].map((l) => `[${l}]`).join("");
    filters.push(
      `${mixIn}amix=inputs=${soundLabels.length + 1}:duration=first:dropout_transition=0:normalize=0[amix]`
    );
    aLabel = "amix";
  }

  const args = [
    "-y",
    ...inputs,
    "-filter_complex", filters.join(";"),
    "-map", `[${vLabel}]`,
    "-map", `[${aLabel}]`,
    "-c:v", "libx264",
    "-preset", spec.preset,
    "-crf", String(spec.crf),
    "-profile:v", "high",
    "-pix_fmt", "yuv420p",
    "-color_range", "tv",
    "-colorspace", "bt709",
    "-c:a", "aac",
    "-b:a", "192k",
    "-movflags", "+faststart",
    "-t", num(spec.duration),
    job.outPath,
  ];

  await new Promise<void>((resolve, reject) => {
    const proc = spawn("ffmpeg", args);
    job.proc = proc;
    proc.stderr.on("data", (chunk: Buffer) => {
      const text = chunk.toString();
      job.log.push(text);
      if (job.log.length > 200) job.log.shift();
      const m = /time=(\d+):(\d+):([\d.]+)/.exec(text);
      if (m) {
        const t = Number(m[1]) * 3600 + Number(m[2]) * 60 + Number(m[3]);
        job.progress = Math.min(0.99, t / Math.max(0.1, spec.duration));
      }
    });
    proc.on("error", (err) =>
      reject(
        err.message.includes("ENOENT")
          ? new Error("ffmpeg was not found. Install it with: brew install ffmpeg")
          : err
      )
    );
    proc.on("close", (code) => {
      if (code === 0) resolve();
      else if (job.error) reject(new Error(job.error));
      else reject(new Error(`ffmpeg exited with code ${code}.\n${job.log.slice(-8).join("")}`));
    });
  });

  job.progress = 1;
  job.status = "done";
}
