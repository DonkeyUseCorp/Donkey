"use client";

import { apiFetch } from "./api";
import { useEditor } from "./store";
import type { MediaAsset } from "./types";
import { mediaUrl } from "./types";

const uid = () => crypto.randomUUID().slice(0, 8);

export function isVideoFile(file: File) {
  return file.type.startsWith("video/") || /\.(mp4|mov|m4v|webm|mkv)$/i.test(file.name);
}

export function isAudioFile(file: File) {
  return file.type.startsWith("audio/") || /\.(mp3|m4a|aac|wav|ogg|flac)$/i.test(file.name);
}

/** Upload a raw file into the project folder, probe it, and return the asset.
 * Thumbnails/waveform are filled in asynchronously via `enrichAsset`. */
export async function importFileToProject(
  projectId: string,
  file: File
): Promise<MediaAsset | null> {
  // MIME wins over extension: recordings are .webm for both video and audio.
  const type = file.type.startsWith("video/")
    ? "video"
    : file.type.startsWith("audio/")
      ? "audio"
      : isVideoFile(file)
        ? "video"
        : isAudioFile(file)
          ? "audio"
          : null;
  if (!type) return null;

  const form = new FormData();
  form.append("file", file, file.name);
  const res = await apiFetch(`/api/cut/projects/${projectId}/media`, {
    method: "POST",
    body: form,
  });
  const body = (await res.json()) as { fileName?: string; error?: string };
  if (!res.ok || !body.fileName) throw new Error(body.error ?? "Upload failed.");

  const url = mediaUrl(projectId, body.fileName);
  const asset: MediaAsset = {
    id: uid(),
    fileName: body.fileName,
    name: file.name,
    type,
    duration: 0,
    url,
  };

  if (type === "video") {
    const v = await loadVideoMeta(url);
    if (v.videoWidth === 0) {
      // A "video" container with no video stream is really audio.
      asset.type = "audio";
      asset.duration = v.duration;
    } else {
      asset.duration = v.duration;
      asset.width = v.videoWidth;
      asset.height = v.videoHeight;
    }
  } else {
    asset.duration = await loadAudioDuration(url);
  }
  return asset;
}

/** Generate filmstrip thumbnails / waveform peaks and merge them into the
 * store. Safe to call repeatedly; skips assets that are already enriched. */
export async function enrichAsset(asset: MediaAsset) {
  try {
    if (asset.type === "video" && !asset.thumbs?.length) {
      const { thumbs, thumbStep } = await makeThumbs(asset.url, asset.duration);
      useEditor.getState().updateAsset(asset.id, { thumbs, thumbStep });
    } else if (asset.type === "audio" && !asset.peaks?.length) {
      const peaks = await makePeaks(asset.url);
      useEditor.getState().updateAsset(asset.id, { peaks });
    }
  } catch {
    // Thumbnails and waveforms are decorative; editing works without them.
  }
}

/** Waveform peaks on demand — e.g. when a video clip's audio is detached
 * onto the soundtrack track (video assets don't get peaks at import). */
export async function ensurePeaks(asset: MediaAsset) {
  try {
    if (!asset.peaks?.length) {
      const peaks = await makePeaks(asset.url);
      useEditor.getState().updateAsset(asset.id, { peaks });
    }
  } catch {
    // Waveforms are decorative; editing works without them.
  }
}

/** MediaRecorder webm files report Infinity until seeked to the end. */
function ensureFiniteDuration(el: HTMLVideoElement | HTMLAudioElement): Promise<number> {
  if (Number.isFinite(el.duration) && el.duration > 0) return Promise.resolve(el.duration);
  return new Promise((resolve) => {
    const done = () => {
      el.removeEventListener("durationchange", done);
      clearTimeout(timer);
      el.currentTime = 0;
      resolve(Number.isFinite(el.duration) ? el.duration : 0);
    };
    const timer = setTimeout(done, 4000);
    el.addEventListener("durationchange", done);
    el.currentTime = 1e7;
  });
}

function loadVideoMeta(url: string): Promise<HTMLVideoElement> {
  return new Promise((resolve, reject) => {
    const v = document.createElement("video");
    v.preload = "metadata";
    v.muted = true;
    // Media may come from the engine on another origin; anonymous CORS keeps
    // canvas frame grabs (filmstrips, AI captures) from tainting.
    v.crossOrigin = "anonymous";
    v.src = url;
    v.onloadedmetadata = () => void ensureFiniteDuration(v).then(() => resolve(v));
    v.onerror = () => reject(new Error("Could not read this video file."));
  });
}

function loadAudioDuration(url: string): Promise<number> {
  return new Promise((resolve, reject) => {
    const a = new Audio();
    a.preload = "metadata";
    a.src = url;
    a.onloadedmetadata = () => void ensureFiniteDuration(a).then(resolve);
    a.onerror = () => reject(new Error("Could not read this audio file."));
  });
}

// Filmstrip frames render at 60 CSS px tall — capture at 3× so they stay sharp
// on Retina (and when a tall timeline scales the row up).
const THUMB_H = 180;

async function makeThumbs(url: string, duration: number) {
  const v = await loadVideoMeta(url);
  // One frame every ~2s (min 10, max 24) so long clips don't repeat frames.
  const count = Math.min(24, Math.max(10, Math.round(duration / 2)));
  const thumbStep = duration / count;
  const aspect = v.videoWidth / Math.max(1, v.videoHeight);
  const w = Math.max(64, Math.round(THUMB_H * aspect));
  const canvas = document.createElement("canvas");
  canvas.width = w;
  canvas.height = THUMB_H;
  const ctx = canvas.getContext("2d")!;
  ctx.imageSmoothingQuality = "high";
  const thumbs: string[] = [];
  for (let i = 0; i < count; i++) {
    const t = Math.min(duration - 0.05, (i + 0.5) * thumbStep);
    await seekTo(v, Math.max(0, t));
    ctx.drawImage(v, 0, 0, w, THUMB_H);
    thumbs.push(canvas.toDataURL("image/jpeg", 0.92));
  }
  v.removeAttribute("src");
  v.load();
  return { thumbs, thumbStep };
}

function seekTo(v: HTMLVideoElement, t: number): Promise<void> {
  return new Promise((resolve) => {
    const done = () => {
      v.removeEventListener("seeked", done);
      clearTimeout(timer);
      resolve();
    };
    const timer = setTimeout(done, 1500);
    v.addEventListener("seeked", done);
    v.currentTime = t;
  });
}

const PEAK_BUCKETS = 1600;

async function makePeaks(url: string): Promise<number[]> {
  const buf = await (await fetch(url)).arrayBuffer();
  const AC: typeof AudioContext =
    window.AudioContext ?? (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext;
  const ctx = new AC();
  try {
    const audio = await ctx.decodeAudioData(buf);
    const data = audio.getChannelData(0);
    const bucketSize = Math.max(1, Math.floor(data.length / PEAK_BUCKETS));
    const peaks: number[] = [];
    for (let i = 0; i < PEAK_BUCKETS; i++) {
      let max = 0;
      const from = i * bucketSize;
      const to = Math.min(data.length, from + bucketSize);
      for (let j = from; j < to; j += 8) {
        const v = Math.abs(data[j]);
        if (v > max) max = v;
      }
      peaks.push(max);
    }
    return peaks;
  } finally {
    void ctx.close();
  }
}
