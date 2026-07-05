import { spawn } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { mediaPath } from "./projects";

function run(cmd: string, args: string[]): Promise<void> {
  return new Promise((resolve, reject) => {
    const p = spawn(cmd, args);
    let err = "";
    p.stderr.on("data", (d) => (err = (err + d.toString()).slice(-2000)));
    p.on("error", (e) =>
      reject(
        e.message.includes("ENOENT")
          ? new Error("ffmpeg was not found. Install it with: brew install ffmpeg")
          : e
      )
    );
    p.on("close", (code) =>
      code === 0 ? resolve() : reject(new Error(err.split("\n").slice(-3).join("\n")))
    );
  });
}

function probeDims(file: string): Promise<{ width: number; height: number }> {
  return new Promise((resolve) => {
    const p = spawn("ffprobe", [
      "-v", "error",
      "-select_streams", "v:0",
      "-show_entries", "stream=width,height",
      "-of", "csv=p=0",
      file,
    ]);
    let out = "";
    p.stdout.on("data", (d) => (out += d));
    p.on("close", () => {
      const [w, h] = out.trim().split(",").map(Number);
      resolve({ width: w || 1080, height: h || 1920 });
    });
    p.on("error", () => resolve({ width: 1080, height: 1920 }));
  });
}

export interface FreezeFraming {
  fit: "fit" | "fill";
  panX: number;
  panY: number;
}

/**
 * Render a still-video clip from one frame of a project media file
 * (a freeze frame), written into the project's media folder.
 *
 * When `frame` is given the still is composited exactly as the preview shows
 * it — letterboxed (fit) or crop-panned (fill) into the project frame — so
 * the capture is locked to the aspect at capture time. Switching the project
 * aspect later letterboxes the baked still; capture another to re-fit.
 */
export async function makeFreezeFrame(
  projectId: string,
  sourceFile: string,
  srcTime: number,
  duration: number,
  frame?: { w: number; h: number },
  framing?: FreezeFraming
): Promise<{ fileName: string; duration: number; width: number; height: number }> {
  const src = mediaPath(projectId, sourceFile);
  const dur = Math.min(10, Math.max(0.5, duration));
  const stampTime = Math.max(0, srcTime);
  const tmp = await mkdtemp(path.join(os.tmpdir(), "veditor-freeze-"));
  const d = new Date();
  const pad = (n: number) => String(n).padStart(2, "0");
  const fileName = `freeze-${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}-${crypto.randomUUID().slice(0, 4)}.mp4`;
  try {
    const png = path.join(tmp, "frame.png");
    await run("ffmpeg", ["-y", "-ss", stampTime.toFixed(3), "-i", src, "-frames:v", "1", png]);

    let vf: string | null = null;
    if (frame) {
      const { w, h } = frame;
      if (framing?.fit === "fill") {
        // Same crop-window math as the preview canvas: pan -1..1 → 0..1.
        const kx = (0.5 + (framing.panX ?? 0) / 2).toFixed(4);
        const ky = (0.5 + (framing.panY ?? 0) / 2).toFixed(4);
        vf = `scale=${w}:${h}:force_original_aspect_ratio=increase,crop=${w}:${h}:(iw-ow)*${kx}:(ih-oh)*${ky}`;
      } else {
        vf = `scale=${w}:${h}:force_original_aspect_ratio=decrease,pad=${w}:${h}:(ow-iw)/2:(oh-ih)/2:black`;
      }
    }

    await run("ffmpeg", [
      "-y",
      "-loop", "1",
      "-i", png,
      "-t", dur.toFixed(3),
      "-r", "30",
      ...(vf ? ["-vf", vf] : []),
      "-c:v", "libx264",
      "-preset", "veryfast",
      "-pix_fmt", "yuv420p",
      mediaPath(projectId, fileName),
    ]);
    if (frame) return { fileName, duration: dur, width: frame.w, height: frame.h };
    const dims = await probeDims(png);
    return { fileName, duration: dur, width: dims.width, height: dims.height };
  } finally {
    void rm(tmp, { recursive: true, force: true });
  }
}
