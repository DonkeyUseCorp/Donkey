import { spawn } from "node:child_process";
import { stat } from "node:fs/promises";
import path from "node:path";

/** Does a file/dir exist? (stat, coerced to a boolean.) */
export async function exists(p: string) {
  return stat(p).then(
    () => true,
    () => false
  );
}

/**
 * First variant of `base` (stem, stem-1, stem-2, …) whose resolved path does
 * not already exist. Used to avoid clobbering when copying/saving media.
 */
export async function uniqueName(base: string, pathFor: (name: string) => string) {
  const ext = path.extname(base);
  const stem = base.slice(0, base.length - ext.length) || "media";
  let name = base;
  for (let n = 1; await exists(pathFor(name)); n++) name = `${stem}-${n}${ext}`;
  return name;
}

/** ffmpeg time/value formatting: millisecond precision, fixed 3 decimals. */
export const num = (n: number) => (Math.round(n * 1000) / 1000).toFixed(3);

/** Round to hundredths (cue/timeline times). */
export const round = (n: number) => Math.round(n * 100) / 100;

/**
 * Whether a media file carries a stream of the given kind ("a" audio /
 * "v" video). Resolves false only when ffprobe reports no such stream; a
 * probe that errors is reported by `onProbeError` so callers can decide
 * whether to assume the stream is present rather than silently dropping it.
 */
export function hasStream(
  file: string,
  kind: "a" | "v",
  onProbeError?: (err: Error) => void
): Promise<boolean> {
  return new Promise((resolve) => {
    const p = spawn("ffprobe", [
      "-v", "error",
      "-select_streams", kind,
      "-show_entries", "stream=codec_type",
      "-of", "csv=p=0",
      file,
    ]);
    let out = "";
    p.stdout.on("data", (d) => (out += d));
    p.on("close", (code) => {
      // A non-zero exit means the probe itself failed, not "no stream".
      if (code !== 0) onProbeError?.(new Error(`ffprobe exited ${code} for ${file}`));
      resolve(out.trim().length > 0);
    });
    p.on("error", (err) => {
      onProbeError?.(err);
      resolve(false);
    });
  });
}
