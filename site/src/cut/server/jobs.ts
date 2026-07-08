import { spawn, type ChildProcess } from "node:child_process";
import { mkdir, mkdtemp, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assertLocalRuntime } from "./local-only";
import { createJobRegistry } from "./jobRegistry";
import { exportsDir, mediaPath, projectDir, readProject } from "./projects";
import { atempoChain, hasStream, num } from "./util";

export interface ExportSpec {
  projectId: string;
  /** "preview" renders the low-res hover proxy into the project's preview.mp4
   * instead of a stamped file in exports/. */
  target?: "export" | "preview";
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
    /** "fit" letterboxes (default); "fill" covers the region and crops. */
    fit?: "fit" | "fill";
    panX?: number; // crop-window pan -1..1 (fill mode, full frame)
    panY?: number;
    /** Region of the frame this clip fills; absent = full frame. */
    frame?: { x: number; y: number; w: number; h: number };
    speed?: number; // playback rate, default 1
    /** Cross-dissolve into the next clip, in timeline seconds (overlap). */
    transition?: number;
    /** Edge-transition ramps, timeline seconds from this segment's head/tail:
     * fades to/from black and zoom pushes. Cross zoom arrives as a tailZoom on
     * one clip plus a headZoom on the next, riding the crossfade overlap. */
    headFade?: number;
    tailFade?: number;
    headZoom?: number;
    tailZoom?: number;
    /** Hidden clips keep their slot but render black + silent. */
    hidden?: boolean;
  }[];
  /** Upper video tracks composited over the base, bottom track first. */
  overlayVideos?: {
    file: string;
    in: number;
    out: number;
    start: number; // timeline position, seconds
    track: number;
    /** Region of the frame this overlay fills; absent = full frame. */
    frame?: { x: number; y: number; w: number; h: number };
    fit?: "fit" | "fill";
    muted: boolean;
    speed?: number;
  }[];
  audio: {
    file: string;
    in: number;
    out: number;
    start: number;
    volume: number;
    fadeIn?: number;
    fadeOut?: number;
    /** Playback rate (detached-audio clips inherit their video clip's speed). */
    speed?: number;
  }[];
  overlays: { file: string; start: number; end: number }[];
}

export interface Job {
  id: string;
  projectId: string;
  /** "preview" is the internal hover-proxy render; only "export" jobs are
   * surfaced to the client for reconnect/download. */
  target: "export" | "preview";
  status: "running" | "done" | "error";
  progress: number; // 0..1
  error?: string;
  tmpDir: string;
  outPath: string;
  outName: string;
  proc?: ChildProcess;
  log: string[];
}

const MAX_RUNNING = 2; // concurrent ffmpeg exports
// Survives dev-server module reloads; caps the terminal backlog.
const { jobs, runningCount, retire } = createJobRegistry<Job>("__veditorJobs");

export function getJob(id: string) {
  return jobs.get(id);
}

/** Running and recently-settled export jobs for a project, so a client that
 * reopened (or reloaded) can reconnect to an export still in flight. */
export function listJobsForProject(projectId: string) {
  return [...jobs.values()]
    .filter((j) => j.projectId === projectId && j.target !== "preview")
    .map((j) => ({
      id: j.id,
      status: j.status,
      progress: j.progress,
      outName: j.outName,
      error: j.error,
    }));
}

export function cancelJob(id: string) {
  const job = jobs.get(id);
  if (job?.proc && job.status === "running") {
    job.proc.kill("SIGKILL");
    job.status = "error";
    job.error = "Export canceled.";
    retire(job);
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
  const id = crypto.randomUUID().slice(0, 12);
  const preview = spec.target === "preview";
  if (runningCount() >= MAX_RUNNING) {
    const job: Job = {
      id,
      projectId: spec.projectId,
      target: preview ? "preview" : "export",
      status: "error",
      progress: 0,
      tmpDir: "",
      outPath: "",
      outName: "",
      error: "Another export is already running — wait for it to finish.",
      log: [],
    };
    jobs.set(id, job);
    retire(job);
    return job;
  }
  // Include the unique job id so two exports in the same second can't collide
  // on the same output path (which would clobber the first render).
  const outName = preview ? "preview.mp4" : `export-${stamp()}-${id}.mp4`;
  const outPath = path.join(
    preview ? projectDir(spec.projectId) : exportsDir(spec.projectId),
    outName
  );
  const job: Job = {
    id,
    projectId: spec.projectId,
    target: preview ? "preview" : "export",
    status: "running",
    progress: 0,
    tmpDir: "",
    outPath,
    outName,
    log: [],
  };
  jobs.set(id, job); // reserve the concurrency slot before the first await

  try {
    await mkdir(path.dirname(outPath), { recursive: true });
    job.tmpDir = await mkdtemp(path.join(os.tmpdir(), "veditor-"));
    if (!(await readProject(spec.projectId))) throw new Error("Project not found.");
    // Overlay PNGs are rendered in the browser and uploaded with the spec.
    for (const [key, value] of form.entries()) {
      if (value instanceof File && key !== "spec") {
        await writeFile(path.join(job.tmpDir, path.basename(key)), Buffer.from(await value.arrayBuffer()));
      }
    }
    void runExport(job, spec)
      .catch((err: unknown) => {
        job.status = "error";
        job.error = err instanceof Error ? err.message : String(err);
        void rm(job.outPath, { force: true }); // no half-written files in exports/
      })
      .finally(() => {
        void rm(job.tmpDir, { recursive: true, force: true }); // overlay tmp, win or lose
        retire(job);
      });
  } catch (err) {
    job.status = "error";
    job.error = err instanceof Error ? err.message : String(err);
    if (job.tmpDir) void rm(job.tmpDir, { recursive: true, force: true });
    retire(job);
  }
  return job;
}

/** The H.264 encoder to use, probed once against the same `ffmpeg` the exports
 * spawn. Prefer libx264 (CRF + presets) when the build carries it — the dev
 * Homebrew ffmpeg does. The bundled engine ffmpeg is LGPL (`--disable-gpl`), so
 * it has no libx264 and `-preset`/`-crf` don't exist there; fall back to the
 * always-present VideoToolbox hardware H.264 encoder. */
let h264EncoderCache: Promise<"libx264" | "h264_videotoolbox"> | null = null;
function h264Encoder(): Promise<"libx264" | "h264_videotoolbox"> {
  return (h264EncoderCache ??= new Promise((resolve) => {
    let out = "";
    const proc = spawn("ffmpeg", ["-hide_banner", "-encoders"]);
    proc.stdout?.on("data", (c: Buffer) => (out += c.toString()));
    proc.on("error", () => resolve("h264_videotoolbox"));
    proc.on("close", () => resolve(/\blibx264\b/.test(out) ? "libx264" : "h264_videotoolbox"));
  }));
}

/** VideoToolbox constant quality (1–100, higher = better) from the CRF knob the
 * presets carry (lower CRF = better). Maps the 19/24/30 tiers to ~66/57/46. */
function vtQuality(crf: number) {
  return Math.round(Math.max(35, Math.min(80, 100 - crf * 1.8)));
}

async function resolveMedia(spec: ExportSpec, file: string) {
  const p = mediaPath(spec.projectId, file);
  const info = await stat(p).catch(() => null);
  if (!info?.isFile()) throw new Error(`Media file missing from project: ${file}`);
  return p;
}

/** A clip's effective playback rate (>0, default 1). */
function clipRate(c: ExportSpec["clips"][number]) {
  return c.speed && c.speed > 0 ? c.speed : 1;
}

/** Peak scale of zoom transitions — matches TRANSITION_ZOOM in lib/types.ts. */
const TRANSITION_ZOOM = 1.18;

/** A clip's frame region in even pixels, or null when it fills the whole frame
 * (the common case, which keeps the plain full-frame filter path). */
function regionPx(
  frame: { x: number; y: number; w: number; h: number } | undefined,
  W: number,
  H: number
) {
  if (!frame) return null;
  const even = (n: number) => 2 * Math.round(n / 2);
  const rw = Math.min(W, Math.max(2, even(frame.w * W)));
  const rh = Math.min(H, Math.max(2, even(frame.h * H)));
  // Clamp the origin so rx+rw ≤ W and ry+rh ≤ H — independent even-rounding can
  // otherwise push an edge-touching region a pixel past the frame, which makes
  // the pad filter reject the input ("not within the padded area") and aborts
  // the whole export.
  const rx = Math.max(0, Math.min(even(frame.x * W), W - rw));
  const ry = Math.max(0, Math.min(even(frame.y * H), H - rh));
  if (rx <= 0 && ry <= 0 && rw >= W && rh >= H) return null;
  return { rx, ry, rw, rh };
}

/**
 * Spawn ffmpeg for one pass, tracking `job.proc` so a cancel kills the live
 * process, bounding silence with the stall watchdog, and (when `onProgress` is
 * given) reporting the `time=` cursor from stderr. Rejects with a readable
 * message on a non-zero exit or a missing binary. Shared by the encode pass and
 * the rotation-strip remux.
 */
function runFfmpeg(
  job: Job,
  args: string[],
  onProgress?: (seconds: number) => void
): Promise<void> {
  return new Promise<void>((resolve, reject) => {
    const proc = spawn("ffmpeg", args);
    job.proc = proc;
    // Stall watchdog: legit exports can run long, so bound silence, not total
    // time — kill only if ffmpeg emits nothing for STALL_MS.
    const STALL_MS = 120_000;
    let watchdog: ReturnType<typeof setTimeout> | undefined;
    const bump = () => {
      clearTimeout(watchdog);
      watchdog = setTimeout(() => {
        proc.kill("SIGKILL");
        reject(new Error("Export stalled — no ffmpeg output for 120s."));
      }, STALL_MS);
      watchdog.unref();
    };
    bump();
    proc.stderr.on("data", (chunk: Buffer) => {
      bump();
      const text = chunk.toString();
      job.log.push(text);
      if (job.log.length > 200) job.log.shift();
      if (onProgress) {
        const m = /time=(\d+):(\d+):([\d.]+)/.exec(text);
        if (m) onProgress(Number(m[1]) * 3600 + Number(m[2]) * 60 + Number(m[3]));
      }
    });
    proc.on("error", (err) => {
      clearTimeout(watchdog);
      reject(
        err.message.includes("ENOENT")
          ? new Error("ffmpeg was not found. Install it with: brew install ffmpeg")
          : err
      );
    });
    proc.on("close", (code) => {
      clearTimeout(watchdog);
      if (code === 0) resolve();
      else if (job.error) reject(new Error(job.error));
      else reject(new Error(`ffmpeg exited with code ${code}.\n${job.log.slice(-8).join("")}`));
    });
  });
}

async function runExport(job: Job, spec: ExportSpec) {
  if (spec.clips.length === 0) throw new Error("Nothing to export.");
  const { width: W, height: H, fps } = spec;

  const overlayVideos = spec.overlayVideos ?? [];
  // Tracks below the base (negative) form a backdrop it draws over; tracks above
  // (positive) sit on top. A below track means the base must carry alpha where
  // it's regioned so the backdrop shows through its margins.
  const belowVideos = overlayVideos.filter((o) => o.track < 0).sort((a, b) => a.track - b.track);
  const aboveVideos = overlayVideos.filter((o) => o.track > 0).sort((a, b) => a.track - b.track);
  const hasBelow = belowVideos.length > 0;
  const baseFmt = hasBelow ? "yuva420p" : "yuv420p";
  const padColor = hasBelow ? "black@0.0" : "black";
  // One ffmpeg input per distinct media file (from the project folder),
  // plus one per uploaded overlay PNG.
  const mediaFiles = [
    ...new Set([...spec.clips, ...spec.audio, ...overlayVideos].map((c) => c.file)),
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
      // A probe that errors (timeout, non-zero exit) must not be read as
      // "no stream" — that would silently drop real audio to silence or real
      // video to black. Genuine absence returns false with no error, so on a
      // probe error we assume the stream is present and let ffmpeg map it.
      let audioProbeFailed = false;
      const hasAudio = await hasStream(paths[i], "a", () => (audioProbeFailed = true));
      audioPresence.set(f, hasAudio || audioProbeFailed);
      let videoProbeFailed = false;
      const hasVideo = await hasStream(paths[i], "v", () => (videoProbeFailed = true));
      videoPresence.set(f, hasVideo || videoProbeFailed);
    })
  );
  for (const o of spec.overlays) {
    inputIndex.set(o.file, inputs.length / 2);
    inputs.push("-i", path.join(job.tmpDir, path.basename(o.file)));
  }

  const filters: string[] = [];

  // Per-clip timeline length (source span compressed/expanded by speed).
  const clipDur = (c: ExportSpec["clips"][number]) =>
    Math.max(0.1, (c.out - c.in) / clipRate(c));

  // Per-clip normalized video + audio segments for the join below.
  spec.clips.forEach((c, j) => {
    const idx = inputIndex.get(c.file)!;
    const speed = clipRate(c);
    const dur = clipDur(c);
    // Edge-transition ramps, clamped so head+tail never overrun the segment.
    const hz = Math.max(0, Math.min(c.headZoom ?? 0, dur));
    const tz = Math.max(0, Math.min(c.tailZoom ?? 0, dur - hz));
    const hf = Math.max(0, Math.min(c.headFade ?? 0, dur));
    const tf = Math.max(0, Math.min(c.tailFade ?? 0, dur - hf));
    if (videoPresence.get(c.file) && !c.hidden) {
      const region = regionPx(c.frame, W, H);
      let frame: string;
      if (region) {
        // A regioned base clip (split-screen half) scales into its rect, then
        // pads out to the full frame with black around it.
        const { rx, ry, rw, rh } = region;
        frame =
          c.fit === "fill"
            ? `scale=${rw}:${rh}:force_original_aspect_ratio=increase,crop=${rw}:${rh},` +
              `pad=${W}:${H}:${rx}:${ry}:color=${padColor}`
            : `scale=${rw}:${rh}:force_original_aspect_ratio=decrease:force_divisible_by=2,` +
              `pad=${W}:${H}:${rx}+(${rw}-iw)/2:${ry}+(${rh}-ih)/2:color=${padColor}`;
      } else {
        frame =
          c.fit === "fill"
            ? // Cover the frame, then crop; the pan chooses the visible window.
              `scale=${W}:${H}:force_original_aspect_ratio=increase,` +
              `crop=${W}:${H}:(iw-ow)*${num(0.5 + Math.max(-1, Math.min(1, c.panX ?? 0)) / 2)}` +
              `:(ih-oh)*${num(0.5 + Math.max(-1, Math.min(1, c.panY ?? 0)) / 2)}`
            : `scale=${W}:${H}:force_original_aspect_ratio=decrease,` +
              `pad=${W}:${H}:(ow-iw)/2:(oh-ih)/2:color=${padColor}`;
      }
      // setpts/speed rescales the clip's duration on the timeline.
      const core =
        `[${idx}:v]trim=${num(c.in)}:${num(c.out)},setpts=(PTS-STARTPTS)/${num(speed)},` +
        `fps=${fps},${frame},setsar=1,format=${baseFmt}`;
      const fades =
        (hf > 0.01 ? `,fade=t=in:st=0:d=${num(hf)}` : "") +
        (tf > 0.01 ? `,fade=t=out:st=${num(Math.max(0, dur - tf))}:d=${num(tf)}` : "");
      if (hz > 0.01 || tz > 0.01) {
        // Zoom ramp on the touched slice only: split the segment, run zoompan
        // over the head/tail window, and concat back — the per-frame zoom
        // stays confined to the short transition window. A head ramp settles
        // TRANSITION_ZOOM→1 (zoom out), a tail ramp pushes 1→TRANSITION_ZOOM
        // (zoom in); zoompan clamps z below 1 itself, so the plain arithmetic
        // needs no guards.
        const ramp = (side: "head" | "tail", secs: number) => {
          const frames = Math.max(1, Math.round(secs * fps) - 1);
          const k = num(TRANSITION_ZOOM - 1);
          const z =
            side === "tail"
              ? `1+${k}*in/${frames}`
              : `${num(TRANSITION_ZOOM)}-${k}*in/${frames}`;
          return (
            `zoompan=z=${z}:x=iw/2-(iw/zoom/2):y=ih/2-(ih/zoom/2)` +
            `:d=1:s=${W}x${H}:fps=${fps},setsar=1,format=${baseFmt}`
          );
        };
        const slices: { from: number; to: number; fx?: string }[] = [];
        if (hz > 0.01) slices.push({ from: 0, to: hz, fx: ramp("head", hz) });
        const mid0 = hz > 0.01 ? hz : 0;
        const mid1 = tz > 0.01 ? dur - tz : dur;
        if (mid1 - mid0 > 0.01) slices.push({ from: mid0, to: mid1 });
        if (tz > 0.01) slices.push({ from: dur - tz, to: dur, fx: ramp("tail", tz) });
        if (slices.length === 1) {
          filters.push(`${core},${slices[0].fx}${fades}[v${j}]`);
        } else {
          filters.push(`${core},split=${slices.length}${slices.map((_, k) => `[vs${j}_${k}]`).join("")}`);
          slices.forEach((sl, k) => {
            filters.push(
              `[vs${j}_${k}]trim=${num(sl.from)}:${num(sl.to)},setpts=PTS-STARTPTS` +
                (sl.fx ? `,${sl.fx}` : "") +
                `[vp${j}_${k}]`
            );
          });
          filters.push(
            slices.map((_, k) => `[vp${j}_${k}]`).join("") +
              `concat=n=${slices.length}:v=1:a=0${fades}[v${j}]`
          );
        }
      } else {
        filters.push(`${core}${fades}[v${j}]`);
      }
    } else {
      // No video stream, or a hidden clip: keep the slot transparent (so a below
      // track shows) when one exists, otherwise plain black.
      const slot = hasBelow ? "black@0.0" : "black";
      filters.push(
        `color=c=${slot}:s=${W}x${H}:r=${fps},trim=0:${num(dur)},setpts=PTS-STARTPTS,format=${baseFmt}[v${j}]`
      );
    }
    if (!c.muted && !c.hidden && audioPresence.get(c.file)) {
      const tempo = speed !== 1 ? `${atempoChain(speed)},` : "";
      // The picture's fade edges carry the sound with them; zoom edges don't.
      const afades =
        (hf > 0.01 ? `,afade=t=in:st=0:d=${num(hf)}` : "") +
        (tf > 0.01 ? `,afade=t=out:st=${num(Math.max(0, dur - tf))}:d=${num(tf)}` : "");
      filters.push(
        `[${idx}:a]atrim=${num(c.in)}:${num(c.out)},asetpts=PTS-STARTPTS,${tempo}` +
          `aresample=44100,aformat=sample_fmts=fltp:channel_layouts=stereo,` +
          `apad=whole_dur=${num(dur)},atrim=0:${num(dur)}${afades}[a${j}]`
      );
    } else {
      filters.push(
        `anullsrc=r=44100:cl=stereo,atrim=0:${num(dur)},asetpts=PTS-STARTPTS[a${j}]`
      );
    }
  });

  // Join the segments. Adjacent clips with a transition cross-dissolve
  // (xfade/acrossfade, overlapping by the transition length); the rest hard-cut
  // (concat). Fold left so mixed sequences chain correctly.
  let vAcc = "v0";
  let aAcc = "a0";
  let acc = clipDur(spec.clips[0]); // running timeline length of the accumulator
  for (let j = 1; j < spec.clips.length; j++) {
    const prev = spec.clips[j - 1];
    const durJ = clipDur(spec.clips[j]);
    // The overlap can't exceed most of either clip, matching the editor clamp.
    const d = Math.min(prev.transition ?? 0, acc * 0.9, durJ * 0.9);
    const vOut = `vj${j}`;
    const aOut = `aj${j}`;
    if (d > 0.01) {
      const offset = Math.max(0, acc - d);
      filters.push(`[${vAcc}][v${j}]xfade=transition=fade:duration=${num(d)}:offset=${num(offset)}[${vOut}]`);
      filters.push(`[${aAcc}][a${j}]acrossfade=d=${num(d)}[${aOut}]`);
      acc = acc + durJ - d;
    } else {
      filters.push(`[${vAcc}][v${j}]concat=n=2:v=1:a=0[${vOut}]`);
      filters.push(`[${aAcc}][a${j}]concat=n=2:v=0:a=1[${aOut}]`);
      acc = acc + durJ;
    }
    vAcc = vOut;
    aAcc = aOut;
  }

  // Composite the video stack bottom→top: below-base tracks form a backdrop the
  // base draws over (a regioned base leaves them showing), then the above-base
  // tracks sit on top. A full-frame layer covers; a regioned one shares the frame
  // (split half) or floats (PiP). Overlay audio (unless muted) mixes in below.
  const overlaySoundLabels: string[] = [];
  let ovk = 0;
  // Overlay one track clip onto `onto`, returning the new label; also queues its
  // audio. Reused for the below backdrop and the above-base stack.
  const addOverlay = (oc: (typeof overlayVideos)[number], onto: string): string => {
    if (!videoPresence.get(oc.file)) return onto;
    const idx = inputIndex.get(oc.file)!;
    const ospeed = oc.speed && oc.speed > 0 ? oc.speed : 1;
    const olen = Math.max(0.1, (oc.out - oc.in) / ospeed);
    const end = Math.min(oc.start + olen, spec.duration);
    const region = regionPx(oc.frame, W, H);
    const cover = oc.fit === "fill" || (oc.fit == null && !region);
    let framing: string;
    let pos: string;
    if (!region) {
      framing = cover
        ? `scale=${W}:${H}:force_original_aspect_ratio=increase,crop=${W}:${H}`
        : `scale=${W}:${H}:force_original_aspect_ratio=decrease:force_divisible_by=2`;
      pos = cover ? "0:0" : `x=(${W}-w)/2:y=(${H}-h)/2`;
    } else {
      const { rx, ry, rw, rh } = region;
      framing = cover
        ? `scale=${rw}:${rh}:force_original_aspect_ratio=increase,crop=${rw}:${rh}`
        : `scale=${rw}:${rh}:force_original_aspect_ratio=decrease:force_divisible_by=2`;
      pos = cover ? `${rx}:${ry}` : `x=${rx}+(${rw}-w)/2:y=${ry}+(${rh}-h)/2`;
    }
    const k = ovk++;
    const seg = `ovv${k}`;
    // tpad delays the clip to its timeline start without a leading-frame stall.
    filters.push(
      `[${idx}:v]trim=${num(oc.in)}:${num(oc.out)},setpts=(PTS-STARTPTS)/${num(ospeed)},` +
        `fps=${fps},${framing},setsar=1,format=yuv420p,tpad=start_duration=${num(oc.start)}[${seg}]`
    );
    const next = `vovv${k}`;
    filters.push(
      `[${onto}][${seg}]overlay=${pos}:enable='between(t,${num(oc.start)},${num(end)})':eof_action=pass[${next}]`
    );
    if (!oc.muted && audioPresence.get(oc.file)) {
      const tempo = ospeed !== 1 ? `${atempoChain(ospeed)},` : "";
      const delayMs = Math.max(0, Math.round(oc.start * 1000));
      const lab = `ovs${k}`;
      filters.push(
        `[${idx}:a]atrim=${num(oc.in)}:${num(oc.out)},asetpts=PTS-STARTPTS,${tempo}` +
          `aresample=44100,aformat=sample_fmts=fltp:channel_layouts=stereo,adelay=${delayMs}:all=1[${lab}]`
      );
      overlaySoundLabels.push(lab);
    }
    return next;
  };

  let vLabel = vAcc;
  if (hasBelow) {
    // Backdrop = black + the below-base tracks; the alpha-carrying base draws
    // over it (regioned margins reveal the backdrop), then flatten for encoding.
    filters.push(
      `color=c=black:s=${W}x${H}:r=${fps},trim=0:${num(spec.duration)},setpts=PTS-STARTPTS,format=yuva420p[below0]`
    );
    let belowLabel = "below0";
    for (const oc of belowVideos) belowLabel = addOverlay(oc, belowLabel);
    filters.push(`[${belowLabel}][${vAcc}]overlay=0:0[basecomp]`);
    filters.push(`[basecomp]format=yuv420p[baseflat]`);
    vLabel = "baseflat";
  }
  for (const oc of aboveVideos) vLabel = addOverlay(oc, vLabel);

  // Burn in text overlays, each windowed to its timeline range.
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
    const speed = a.speed && a.speed > 0 ? a.speed : 1;
    const delayMs = Math.max(0, Math.round(a.start * 1000));
    // Timeline length after any speed change; fade offsets are in these
    // (post-tempo) seconds, so atempo runs before the fades.
    const len = Math.max(0.1, (a.out - a.in) / speed);
    const tempo = speed !== 1 ? `${atempoChain(speed)},` : "";
    const fades: string[] = [];
    if (a.fadeIn && a.fadeIn > 0.01) fades.push(`afade=t=in:st=0:d=${num(a.fadeIn)}`);
    if (a.fadeOut && a.fadeOut > 0.01)
      fades.push(`afade=t=out:st=${num(Math.max(0, len - a.fadeOut))}:d=${num(a.fadeOut)}`);
    filters.push(
      `[${idx}:a]atrim=${num(a.in)}:${num(a.out)},asetpts=PTS-STARTPTS,${tempo}` +
        `aresample=44100,aformat=sample_fmts=fltp:channel_layouts=stereo,` +
        `volume=${num(a.volume)},` +
        (fades.length ? fades.join(",") + "," : "") +
        `adelay=${delayMs}:all=1[snd${k}]`
    );
    soundLabels.push(`snd${k}`);
  });

  let aLabel = aAcc;
  const extraSound = [...soundLabels, ...overlaySoundLabels];
  if (extraSound.length > 0) {
    const mixIn = [aAcc, ...extraSound].map((l) => `[${l}]`).join("");
    filters.push(
      `${mixIn}amix=inputs=${extraSound.length + 1}:duration=first:dropout_transition=0:normalize=0[amix]`
    );
    aLabel = "amix";
  }

  const enc = await h264Encoder();
  const videoCodecArgs =
    enc === "libx264"
      ? ["-c:v", "libx264", "-preset", spec.preset, "-crf", String(spec.crf)]
      : ["-c:v", "h264_videotoolbox", "-q:v", String(vtQuality(spec.crf)), "-allow_sw", "1"];

  // Encode into the tmp dir, then re-emit the container to strip a stray output
  // rotation flag (see the strip pass below). Keeping the encode intermediate
  // lets the second pass own faststart.
  const encodePath = path.join(job.tmpDir, "encode.mp4");
  await runFfmpeg(
    job,
    [
      "-y",
      ...inputs,
      "-filter_complex", filters.join(";"),
      "-map", `[${vLabel}]`,
      "-map", `[${aLabel}]`,
      ...videoCodecArgs,
      "-profile:v", "high",
      "-pix_fmt", "yuv420p",
      "-color_range", "tv",
      "-colorspace", "bt709",
      "-c:a", "aac",
      "-b:a", "192k",
      "-t", num(spec.duration),
      encodePath,
    ],
    (t) => (job.progress = Math.min(0.99, t / Math.max(0.1, spec.duration)))
  );

  // ffmpeg's autorotation already baked each source's display matrix into the
  // pixels, so the encode's frames are upright. But for a complex filtergraph it
  // ALSO copies the first input's display-matrix side data onto the output
  // stream — so a phone (portrait) source lands as a correct 1080×1920 file
  // tagged with a stray 90° rotation, and players re-rotate it into a sideways
  // "desktop" frame. `-display_rotation 0` overrides that matrix to identity; a
  // stream copy re-emits the (already correct) pixels and audio unchanged and
  // writes the faststart-optimized final file.
  await runFfmpeg(job, [
    "-y",
    "-display_rotation", "0",
    "-i", encodePath,
    "-map", "0",
    "-c", "copy",
    "-movflags", "+faststart",
    job.outPath,
  ]);

  job.progress = 1;
  job.status = "done";
}
