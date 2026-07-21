"use client";

import { apiFetch, apiJson } from "./api";
import { useEditor } from "./store";
import type { AssetType, AudioClip, MediaAsset, ProjectSummary, StoredAsset, VideoClip } from "./types";
import { IMAGE_CLIP_SECONDS, mediaUrl } from "./types";

const uid = () => crypto.randomUUID().slice(0, 8);

/** True when a dropped OS file is something Cut can turn into a project. */
export function isMediaFile(file: File) {
  return (
    file.type.startsWith("video/") ||
    file.type.startsWith("audio/") ||
    file.type.startsWith("image/") ||
    isVideoFile(file) ||
    isAudioFile(file) ||
    isImageFile(file)
  );
}

/** Create a fresh project seeded from a single desktop file: upload the media,
 * lay it on the timeline, and persist — no editor round-trip. Returns the new
 * project's id, or null if the file isn't video/audio. */
export async function createProjectFromFile(
  file: File,
  folderId: string | null
): Promise<string | null> {
  if (!isMediaFile(file)) return null;
  const name = file.name.replace(/\.[^./]+$/, "") || "Untitled";
  const res = await apiFetch("/api/cut/projects", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name, folderId }),
  });
  const project = await apiJson<ProjectSummary>(res);
  if (!res.ok || !project.id) throw new Error(project.error ?? "Could not create the project.");

  const asset = await importFileToProject(project.id, file);
  // Media the engine rejects leaves an empty project rather than a dangling id.
  if (!asset) return project.id;

  const stored: StoredAsset = {
    id: asset.id,
    fileName: asset.fileName,
    name: asset.name,
    type: asset.type,
    duration: asset.duration,
    ...(asset.width !== undefined ? { width: asset.width } : {}),
    ...(asset.height !== undefined ? { height: asset.height } : {}),
  };
  const doc: Partial<{ assets: StoredAsset[]; clips: VideoClip[]; audioClips: AudioClip[] }> = {
    assets: [stored],
  };
  if (asset.type === "video" || asset.type === "image") {
    const out = asset.type === "image" ? IMAGE_CLIP_SECONDS : asset.duration;
    doc.clips = [{ id: uid(), assetId: asset.id, track: 0, start: 0, in: 0, out, muted: false }];
  } else {
    doc.audioClips = [
      { id: uid(), assetId: asset.id, start: 0, in: 0, out: asset.duration, volume: 1 },
    ];
  }
  await apiFetch(`/api/cut/projects/${project.id}`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(doc),
  });
  return project.id;
}

export function isVideoFile(file: File) {
  return file.type.startsWith("video/") || /\.(mp4|mov|m4v|webm|mkv)$/i.test(file.name);
}

export function isAudioFile(file: File) {
  return file.type.startsWith("audio/") || /\.(mp3|m4a|aac|wav|ogg|flac)$/i.test(file.name);
}

export function isImageFile(file: File) {
  return file.type.startsWith("image/") || /\.(png|jpe?g|webp|gif|avif|bmp)$/i.test(file.name);
}

export function isTextFile(file: File) {
  return file.type.startsWith("text/") || /\.(txt|md|markdown|srt|vtt|csv|json)$/i.test(file.name);
}

/** Upload a raw file into the project folder, probe it, and return the asset.
 * Thumbnails/waveform are filled in asynchronously via `enrichAsset`. */
export async function importFileToProject(
  projectId: string,
  file: File
): Promise<MediaAsset | null> {
  // MIME wins over extension: recordings are .webm for both video and audio.
  const type: AssetType | null = file.type.startsWith("video/")
    ? "video"
    : file.type.startsWith("audio/")
      ? "audio"
      : file.type.startsWith("image/")
        ? "image"
        : isVideoFile(file)
          ? "video"
          : isAudioFile(file)
            ? "audio"
            : isImageFile(file)
              ? "image"
              : null;
  if (!type) return null;

  const form = new FormData();
  form.append("file", file, file.name);
  const res = await apiFetch(`/api/cut/projects/${projectId}/media`, {
    method: "POST",
    body: form,
  });
  const body = await apiJson<{ fileName?: string }>(res);
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
  } else if (type === "image") {
    // Images have no intrinsic duration; the timeline clip carries its length.
    const dims = await loadImageMeta(url);
    asset.width = dims.width;
    asset.height = dims.height;
  } else {
    // Decode for a sample-exact duration (HTMLAudioElement overestimates MP3s,
    // leaving a placed clip running past its real audio) and reuse the same
    // decode for the waveform, so enrichAsset has nothing left to do.
    const audio = await decodeAudio(url);
    if (audio && audio.duration > 0) {
      asset.duration = audio.duration;
      asset.peaks = peaksFromChannel(audio.getChannelData(0));
    } else {
      asset.duration = await loadAudioDuration(url);
    }
  }
  return asset;
}

/** Natural pixel size of an image URL, for framing on the timeline. */
function loadImageMeta(url: string): Promise<{ width: number; height: number }> {
  return new Promise((resolve) => {
    const img = new Image();
    img.onload = () => resolve({ width: img.naturalWidth, height: img.naturalHeight });
    img.onerror = () => resolve({ width: 0, height: 0 });
    img.src = url;
  });
}

/** Store a fetchable image (a stock tile) in the project's media as a
 * first-class image asset at its native resolution — no video baking — and
 * register it, without placing it on the timeline. Callers choose where it
 * lands. */
export async function importImage(
  projectId: string,
  image: { url: string; name: string }
): Promise<MediaAsset> {
  const dl = await fetch(image.url);
  if (!dl.ok) throw new Error("Could not read the image.");
  const blob = await dl.blob();
  const form = new FormData();
  form.append("file", blob, image.url.split("/").pop() || "image.png");
  form.append("name", image.name);
  const res = await apiFetch(`/api/cut/projects/${projectId}/image`, {
    method: "POST",
    body: form,
  });
  const body = await apiJson<MediaAsset>(res);
  if (!res.ok || !body.fileName) throw new Error(body.error ?? "Could not add the image.");
  // A stock image lands on the timeline where the caller places it, not in the
  // Media panel — tag it so it stays out.
  const asset: MediaAsset = { ...body, url: mediaUrl(projectId, body.fileName), origin: "stock" };
  useEditor.getState().addAsset(asset);
  void enrichAsset(asset);
  return asset;
}

/** Store a fetchable video (a stock clip) in the project's media as a regular
 * video asset and register it, without placing it on the timeline. Callers
 * choose where it lands. */
export async function importStockVideo(
  projectId: string,
  video: { url: string; name: string }
): Promise<MediaAsset> {
  const dl = await fetch(video.url);
  if (!dl.ok) throw new Error("Could not read the video.");
  const blob = await dl.blob();
  const file = new File([blob], video.url.split("/").pop() || "video.mp4", {
    type: blob.type || "video/mp4",
  });
  const asset = await importFileToProject(projectId, file);
  if (!asset) throw new Error("Could not add the video.");
  asset.name = video.name;
  // Like a stock image, it lands where the caller places it, not in Media.
  asset.origin = "stock";
  useEditor.getState().addAsset(asset);
  void enrichAsset(asset);
  return asset;
}

/** Store a bundled stock-music bed in the project's media as a regular audio
 * asset and register it, without placing it on the timeline — callers choose
 * where it lands (the soundtrack). Tagged "stock" so it stays out of Media. */
export async function importStockMusic(
  projectId: string,
  music: { url: string; name: string }
): Promise<MediaAsset> {
  const dl = await fetch(music.url);
  if (!dl.ok) throw new Error("Could not read the music.");
  const blob = await dl.blob();
  const file = new File([blob], music.url.split("/").pop() || "music.mp3", {
    type: blob.type || "audio/mpeg",
  });
  const asset = await importFileToProject(projectId, file);
  if (!asset) throw new Error("Could not add the music.");
  asset.name = music.name;
  asset.origin = "stock";
  useEditor.getState().addAsset(asset);
  void enrichAsset(asset);
  return asset;
}

/** Download a media URL (TikTok, YouTube, a tweet, …) into the project
 * through the engine's bundled downloader and register what came back — one
 * asset for a video, one per photo for a photo tweet — without placing
 * anything on the timeline. Callers choose where assets land. `text` is the
 * post text when the URL was a tweet. */
export async function importUrlMedia(
  projectId: string,
  url: string
): Promise<{ assets: MediaAsset[]; text?: string }> {
  const res = await apiFetch(`/api/cut/projects/${projectId}/import-url`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ url }),
  });
  const body = await apiJson<{ files?: { fileName: string; title: string }[]; text?: string }>(res);
  if (!res.ok || !body.files?.length) throw new Error(body.error ?? "Could not import that URL.");
  const assets: MediaAsset[] = [];
  for (const f of body.files) {
    const asset = await assetFromProjectFile(projectId, f.fileName, f.title || "Imported clip");
    useEditor.getState().addAsset(asset);
    void enrichAsset(asset);
    assets.push(asset);
  }
  return { assets, text: body.text };
}

/** Build a runtime asset for a media file the engine already wrote into the
 * project folder (freeze frames, AI generations, URL imports) — probe
 * metadata, no upload. */
export async function assetFromProjectFile(
  projectId: string,
  fileName: string,
  name: string
): Promise<MediaAsset> {
  const url = mediaUrl(projectId, fileName);
  const asset: MediaAsset = {
    id: uid(),
    fileName,
    name,
    type: "video",
    duration: 0,
    url,
  };
  if (/\.(png|jpe?g|webp|gif|avif|bmp)$/i.test(fileName)) {
    asset.type = "image";
    const dims = await loadImageMeta(url);
    asset.width = dims.width;
    asset.height = dims.height;
    return asset;
  }
  const v = await loadVideoMeta(url);
  asset.duration = v.duration;
  if (v.videoWidth === 0) {
    asset.type = "audio";
  } else {
    asset.width = v.videoWidth;
    asset.height = v.videoHeight;
  }
  return asset;
}

/** Generate filmstrip thumbnails / waveform peaks and merge them into the
 * store. Safe to call repeatedly; skips assets that are already enriched. */
export async function enrichAsset(asset: MediaAsset) {
  try {
    if (asset.type === "image") {
      // A still is its own filmstrip: one frame, tiled across the clip.
      if (!asset.thumbs?.length) {
        useEditor.getState().updateAsset(asset.id, { thumbs: [asset.url], thumbStep: IMAGE_CLIP_SECONDS });
      }
    } else if (asset.type === "video" && !asset.thumbs?.length) {
      const key = stripCacheKey(asset.url);
      const cached = await readCachedStrip(key, asset.duration);
      if (cached) {
        useEditor.getState().updateAsset(asset.id, { thumbs: cached.thumbs, thumbStep: cached.thumbStep });
      } else {
        const { thumbs, thumbStep } = await makeThumbs(asset.url, asset.duration);
        useEditor.getState().updateAsset(asset.id, { thumbs, thumbStep });
        writeCachedStrip(key, { thumbs, thumbStep, duration: asset.duration, at: Date.now() });
      }
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

export function loadAudioDuration(url: string): Promise<number> {
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

// Filmstrips persist in IndexedDB keyed by the media file's project path, so
// reopening a project paints clips from cache instead of re-seeking every
// video. Cache failures fall through to regeneration.
const STRIP_DB = "cut-filmstrips";
const STRIP_STORE = "strips";
const STRIP_CAP = 500; // prune oldest beyond this many cached strips

type CachedStrip = { thumbs: string[]; thumbStep: number; duration: number; at: number };

function stripCacheKey(url: string) {
  return new URL(url, window.location.href).pathname;
}

function openStripDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(STRIP_DB, 1);
    req.onupgradeneeded = () => {
      const store = req.result.createObjectStore(STRIP_STORE);
      store.createIndex("at", "at");
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function readCachedStrip(key: string, duration: number): Promise<CachedStrip | null> {
  try {
    const db = await openStripDb();
    const strip = await new Promise<CachedStrip | undefined>((resolve, reject) => {
      const req = db.transaction(STRIP_STORE).objectStore(STRIP_STORE).get(key);
      req.onsuccess = () => resolve(req.result as CachedStrip | undefined);
      req.onerror = () => reject(req.error);
    });
    db.close();
    // A same-path file with a different duration was rewritten; regenerate.
    if (!strip?.thumbs?.length || Math.abs(strip.duration - duration) > 0.25) return null;
    return strip;
  } catch {
    return null;
  }
}

function writeCachedStrip(key: string, strip: CachedStrip) {
  void (async () => {
    try {
      const db = await openStripDb();
      const tx = db.transaction(STRIP_STORE, "readwrite");
      const store = tx.objectStore(STRIP_STORE);
      store.put(strip, key);
      const count = await new Promise<number>((resolve, reject) => {
        const req = store.count();
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => reject(req.error);
      });
      if (count > STRIP_CAP) {
        const cursorReq = store.index("at").openCursor();
        let toDrop = count - STRIP_CAP;
        cursorReq.onsuccess = () => {
          const cursor = cursorReq.result;
          if (!cursor || toDrop <= 0) return;
          cursor.delete();
          toDrop--;
          cursor.continue();
        };
      }
      tx.oncomplete = () => db.close();
      tx.onerror = () => db.close();
    } catch {
      // Cache writes are best-effort; the strip is already on screen.
    }
  })();
}

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

/** Decode an audio URL to a buffer, or null on any failure (a bad/undecodable
 * file). The decoded buffer's duration is sample-exact — the source of truth for
 * an audio clip's length, unlike HTMLAudioElement.duration, which overestimates
 * MP3s and would leave a placed clip running past its real audio. */
async function decodeAudio(url: string): Promise<AudioBuffer | null> {
  try {
    const buf = await (await fetch(url)).arrayBuffer();
    const AC: typeof AudioContext =
      window.AudioContext ??
      (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext;
    const ctx = new AC();
    try {
      return await ctx.decodeAudioData(buf);
    } finally {
      void ctx.close();
    }
  } catch {
    return null;
  }
}

/** Normalized 0..1 waveform peaks from a decoded buffer's first channel. */
function peaksFromChannel(data: Float32Array): number[] {
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
}

async function makePeaks(url: string): Promise<number[]> {
  const audio = await decodeAudio(url);
  return audio ? peaksFromChannel(audio.getChannelData(0)) : [];
}
