"use client";

import type { ClipSpan } from "./types";

// Sample the cut's picture for the visual-subtitles pipeline: a handful of
// small jpeg frames spread along the base track, each stamped with its
// timeline time. Captured in the browser from the same media elements the
// preview uses, so nothing re-renders server-side.

export interface CapturedFrame {
  at: number;
  /** data:image/jpeg;base64,… */
  image: string;
}

const FRAME_W = 480;
const JPEG_Q = 0.72;
const MIN_FRAMES = 4;
const MAX_FRAMES = 20;
/** Aim for one frame every ~2.5s of timeline. */
const SECONDS_PER_FRAME = 2.5;

function loadVideo(url: string): Promise<HTMLVideoElement> {
  return new Promise((resolve, reject) => {
    const v = document.createElement("video");
    v.preload = "metadata";
    v.muted = true;
    // Media may come from the engine on another origin; anonymous CORS keeps
    // the canvas grab from tainting.
    v.crossOrigin = "anonymous";
    v.src = url;
    v.onloadedmetadata = () => resolve(v);
    v.onerror = () => reject(new Error("Could not read a video file for frame capture."));
  });
}

function seekTo(v: HTMLVideoElement, t: number): Promise<void> {
  return new Promise((resolve) => {
    const done = () => {
      v.removeEventListener("seeked", done);
      clearTimeout(timer);
      resolve();
    };
    const timer = setTimeout(done, 2000);
    v.addEventListener("seeked", done);
    v.currentTime = t;
  });
}

/** Capture timeline frames from the base track's visible clips. */
export async function captureTimelineFrames(spans: ClipSpan[]): Promise<CapturedFrame[]> {
  const visible = spans.filter((sp) => !sp.clip.hidden);
  if (visible.length === 0) return [];
  const total = Math.max(...visible.map((sp) => sp.start + sp.len));
  const count = Math.min(
    MAX_FRAMES,
    Math.max(MIN_FRAMES, Math.round(total / SECONDS_PER_FRAME))
  );

  const canvas = document.createElement("canvas");
  const ctx = canvas.getContext("2d");
  if (!ctx) return [];
  ctx.imageSmoothingQuality = "high";

  // One shared element per source file; spans of the same asset reuse it.
  const videos = new Map<string, HTMLVideoElement>();
  const frames: CapturedFrame[] = [];
  try {
    for (let i = 0; i < count; i++) {
      const at = ((i + 0.5) * total) / count;
      const span = visible.find((sp) => at >= sp.start && at < sp.start + sp.len);
      if (!span) continue;
      let v = videos.get(span.asset.id);
      if (!v) {
        try {
          v = await loadVideo(span.asset.url);
        } catch {
          continue; // one unreadable source shouldn't sink the whole capture
        }
        videos.set(span.asset.id, v);
      }
      const speed = span.clip.speed && span.clip.speed > 0 ? span.clip.speed : 1;
      const srcTime = span.clip.in + (at - span.start) * speed;
      await seekTo(v, Math.max(0, Math.min(srcTime, Math.max(0, v.duration - 0.05))));
      if (v.readyState < 2 || !v.videoWidth) continue;
      const w = Math.min(FRAME_W, v.videoWidth);
      const h = Math.round((w / v.videoWidth) * v.videoHeight);
      canvas.width = w;
      canvas.height = h;
      ctx.drawImage(v, 0, 0, w, h);
      try {
        frames.push({ at, image: canvas.toDataURL("image/jpeg", JPEG_Q) });
      } catch {
        // A tainted canvas (unexpected CORS setup) — skip the frame.
      }
    }
  } finally {
    for (const v of videos.values()) {
      v.removeAttribute("src");
      v.load();
    }
  }
  return frames;
}
