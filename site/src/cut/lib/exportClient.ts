"use client";

import { apiFetch, apiJson, apiUrl } from "./api";
import { clipSpeed, getClipSpans, overlayLayers, projectDuration, spanSequence } from "./store";
import { captionStyle, cueOverlay, cueWordWindows, laneCues, subtitleLaneCount, trackPos } from "./subtitles";
import { renderOverlayPng } from "./textRender";
import { FRAME } from "./types";
import type {
  Aspect,
  AudioClip,
  MediaAsset,
  SubtitlesBlock,
  TextOverlay,
  VideoClip,
} from "./types";

export interface ExportSettings {
  width: number;
  height: number;
  fps: number;
  crf: number;
  preset: string;
}

/** Presets are stored portrait (9:16); `presetSettings` flips them for 16:9. */
export const EXPORT_PRESETS = [
  {
    id: "tiktok",
    label: "Best · 1080p",
    detail: "H.264 · best quality",
    settings: { width: 1080, height: 1920, fps: 30, crf: 19, preset: "medium" },
  },
  {
    id: "fast",
    label: "Quick share · 1080p",
    detail: "smaller file, faster",
    settings: { width: 1080, height: 1920, fps: 30, crf: 24, preset: "veryfast" },
  },
  {
    id: "light",
    label: "Draft · 720p",
    detail: "fastest render",
    settings: { width: 720, height: 1280, fps: 30, crf: 24, preset: "veryfast" },
  },
] as const;

export function presetSettings(
  preset: (typeof EXPORT_PRESETS)[number],
  aspect: Aspect
): ExportSettings {
  const { width, height, ...rest } = preset.settings;
  return aspect === "16:9"
    ? { width: height, height: width, ...rest }
    : { width, height, ...rest };
}

/**
 * "Original": the highest resolution the timeline's own footage justifies,
 * along the project aspect. It scales the 1080p base by the sharpest source
 * clip — never below the base (so it is always the highest option), never
 * above 4K, and never upscaled past the source. Unknown source sizes fall
 * back to the base.
 */
export function originalSettings(
  aspect: Aspect,
  clips: VideoClip[],
  assets: MediaAsset[]
): ExportSettings {
  const base = FRAME[aspect];
  const srcLong = Math.max(
    0,
    ...getClipSpans(clips, assets).map((sp) =>
      Math.max(sp.asset.width ?? 0, sp.asset.height ?? 0)
    )
  );
  const k = Math.min(2, Math.max(1, srcLong / Math.max(base.w, base.h) || 1));
  const even = (n: number) => 2 * Math.round((n * k) / 2);
  return { width: even(base.w), height: even(base.h), fps: 30, crf: 19, preset: "medium" };
}

/**
 * Rough output size for a preset, in bytes. The encoder is CRF (variable
 * bitrate), so this is a heuristic: it models H.264 bits-per-pixel as halving
 * every +6 CRF from a ~0.08 bpp anchor at CRF 23, scaled by frame area and fps,
 * plus the fixed 192 kbps AAC audio. Busy footage runs larger and flat footage
 * smaller, so the dialog shows it as an approximation, not a promise.
 */
export function estimateExportBytes(settings: ExportSettings, durationSec: number): number {
  if (durationSec <= 0) return 0;
  const pixelsPerSec = settings.width * settings.height * settings.fps;
  const bpp = 0.08 * 2 ** ((23 - settings.crf) / 6);
  const videoBps = pixelsPerSec * bpp;
  const audioBps = 192_000;
  return ((videoBps + audioBps) * durationSec) / 8;
}

/** Human-readable size estimate matching the finished-export MB display. */
export function formatSizeEstimate(bytes: number): string {
  if (bytes <= 0) return "";
  const mb = bytes / (1024 * 1024);
  if (mb < 1) return "~1 MB";
  if (mb < 1000) return `~${mb < 10 ? mb.toFixed(1) : Math.round(mb)} MB`;
  return `~${(mb / 1024).toFixed(1)} GB`;
}

/** Reveal a rendered export in Finder (local engine only). */
export async function revealExport(projectId: string, file: string) {
  await apiFetch(
    `/api/cut/projects/${projectId}/exports/${encodeURIComponent(file)}/reveal`,
    { method: "POST" }
  );
}

/** Delete a rendered export from the project folder. Throws on failure so the
 * UI can stay truthful instead of optimistically dropping a file that's still
 * on disk (which is why deleted exports used to reappear on the next refresh). */
export async function deleteExport(projectId: string, file: string) {
  const res = await apiFetch(
    `/api/cut/projects/${projectId}/exports/${encodeURIComponent(file)}`,
    { method: "DELETE" }
  );
  if (!res.ok) {
    const body = (await res.json().catch(() => ({}))) as { error?: string };
    throw new Error(body.error ?? "Could not delete the export.");
  }
}

export interface ExportDoc {
  assets: MediaAsset[];
  /** Every video clip, any track (track 0 folds sequentially, others composite). */
  clips: VideoClip[];
  audioClips: AudioClip[];
  overlays: TextOverlay[];
  subtitles: SubtitlesBlock;
  /** Whole-video fades (seconds): in from black / out to black on the final
   * composite. */
  fadeIn?: number;
  fadeOut?: number;
}


/** Build the export FormData from the cut. Media already lives in the project
 * folder — the spec references it by file name; only overlay PNGs travel with
 * the request. Shared by full exports and the low-res hover proxy. */
async function buildExportForm(
  projectId: string,
  doc: ExportDoc,
  settings: ExportSettings,
  target: "export" | "preview"
): Promise<FormData> {
  const spans = getClipSpans(doc.clips, doc.assets);
  const duration = projectDuration(doc);
  const form = new FormData();
  const assetById = new Map(doc.assets.map((a) => [a.id, a]));
  // Overlay-only cuts (empty track 0) still export: track 0 becomes a black bed
  // the length of the project and the overlays/soundtrack composite onto it —
  // the same path as a gap before the first track-0 clip. Refuse only a cut with
  // no renderable content at all.
  const hasOverlayVideo = overlayLayers(doc.clips).some(
    (c) => !c.hidden && assetById.has(c.assetId) && c.start < duration,
  );
  const hasAudio = doc.audioClips.some(
    (a) => !a.hidden && a.start < duration && assetById.has(a.assetId),
  );
  if (spans.length === 0 && !hasOverlayVideo && !hasAudio) {
    throw new Error("Add a video to the timeline first.");
  }

  const clipEntries = spans.map((sp) => ({
    file: sp.asset.fileName,
    in: sp.clip.in,
    out: sp.clip.out,
    muted: sp.clip.muted,
    volume: sp.clip.volume ?? 1,
    fit: sp.clip.fit ?? "fit",
    panX: sp.clip.panX ?? 0,
    panY: sp.clip.panY ?? 0,
    frame: sp.clip.frame,
    speed: clipSpeed(sp.clip),
    transition: sp.transitionOut,
    hidden: sp.clip.hidden,
    // A still: the server loops the image for the clip's length instead of
    // trimming a source span.
    image: sp.asset.type === "image",
    headFade: 0,
    tailFade: 0,
    headZoom: 0,
    tailZoom: 0,
  }));

  // Translate each joint's transition style into per-segment ramps so the
  // server spec stays dumb. Cross zoom rides the crossfade overlap with a zoom
  // ramp on both sides; edge styles ramp one clip's edge around a hard cut
  // (their `transition` ships as 0 overlap, so the join stays a plain concat).
  spans.forEach((sp, i) => {
    const next = spans[i + 1];
    if (!next) return;
    const style = sp.clip.transitionStyle ?? "crossfade";
    const d = sp.clip.transition ?? 0;
    if (d <= 0) return;
    const a = clipEntries[i];
    const b = clipEntries[i + 1];
    if (style === "crosszoom" && sp.transitionOut > 0) {
      a.tailZoom = sp.transitionOut;
      b.headZoom = sp.transitionOut;
    } else if (style === "fadeout") {
      a.tailFade = Math.min(d, sp.len);
    } else if (style === "zoomin") {
      a.tailZoom = Math.min(d, sp.len);
    } else if (style === "fadein") {
      b.headFade = Math.min(d, next.len);
    } else if (style === "zoomout") {
      b.headZoom = Math.min(d, next.len);
    }
  });

  // The server's video graph is a sequential fold, so gaps between the
  // free-placed clips ship as explicit spacer segments: no file, hidden and
  // muted, which the server renders as black + silence for the gap's length.
  const spacer = (len: number) => ({
    file: "",
    in: 0,
    out: len,
    muted: true,
    volume: 0,
    fit: "fit" as const,
    panX: 0,
    panY: 0,
    frame: undefined,
    speed: 1,
    transition: 0,
    hidden: true,
    image: false,
    headFade: 0,
    tailFade: 0,
    headZoom: 0,
    tailZoom: 0,
  });
  // An overlay-only cut has no track-0 spans: the whole base is one black bed.
  const clips =
    spans.length === 0
      ? [spacer(duration)]
      : spanSequence(spans).flatMap(({ gapBefore }, i) => [
          ...(gapBefore > 0 ? [spacer(gapBefore)] : []),
          clipEntries[i],
        ]);

  // Video tracks composited over track 0; hidden ones are dropped.
  const overlayVideos = overlayLayers(doc.clips)
    .filter((c) => !c.hidden && assetById.has(c.assetId) && c.start < duration)
    .map((c) => ({
      file: assetById.get(c.assetId)!.fileName,
      in: c.in,
      out: c.out,
      start: c.start,
      track: c.track,
      frame: c.frame,
      // Pass `fit` through unset so the server's "default full-frame overlay
      // covers what's below" branch fires — normalizing to "fit" defeated it.
      fit: c.fit,
      muted: c.muted,
      volume: c.volume,
      speed: c.speed,
      image: assetById.get(c.assetId)!.type === "image",
    }));

  const audio = doc.audioClips
    .filter((a) => !a.hidden && a.start < duration && assetById.has(a.assetId))
    .map((a) => ({
      file: assetById.get(a.assetId)!.fileName,
      in: a.in,
      out: a.out,
      start: a.start,
      volume: a.volume,
      fadeIn: a.fadeIn ?? 0,
      fadeOut: a.fadeOut ?? 0,
      speed: a.speed,
      duck: a.duck,
    }));

  const overlays: { file: string; start: number; end: number }[] = [];
  for (let i = 0; i < doc.overlays.length; i++) {
    const o = doc.overlays[i];
    if (o.start >= duration || !o.text.trim()) continue;
    const png = await renderOverlayPng(o, settings.width, settings.height);
    const key = `overlay_${i}.png`;
    form.append(key, png, key);
    overlays.push({ file: key, start: o.start, end: Math.min(o.end, duration) });
  }

  // Subtitle stills travel in their own spec lane: the server plays each
  // subtitle track as one concat-demuxer slideshow (with a transparent filler
  // frame for gaps), so karaoke word windows don't each become an ffmpeg
  // input. Tracks overlap each other in time, so every track (language) gets
  // its own slideshow, marked by `lane`.
  const captions: { file: string; start: number; end: number; lane?: number }[] = [];
  if (doc.subtitles.showOnVideo) {
    const capStyle = captionStyle(doc.subtitles.style);
    for (let lane = 0; lane < subtitleLaneCount(doc.subtitles); lane++) {
      const cues = laneCues(doc.subtitles, lane);
      const pos = trackPos(doc.subtitles, capStyle, lane);
      for (let i = 0; i < cues.length; i++) {
        const cue = cues[i];
        if (cue.start >= duration || !cue.text.trim()) continue;
        // Karaoke burns one frame per word window (the spoken word accented);
        // otherwise the whole cue is a single still.
        const windows = doc.subtitles.wordHighlight
          ? cueWordWindows(cue)
          : [{ start: cue.start, end: cue.end }];
        for (let wi = 0; wi < windows.length; wi++) {
          const win = windows[wi];
          if (win.start >= duration) break;
          const png = await renderOverlayPng(
            cueOverlay(cue, capStyle, i === 0, pos, doc.subtitles.wordHighlight ? wi : undefined),
            settings.width,
            settings.height
          );
          const key = windows.length > 1 ? `sub_${lane}_${i}_${wi}.png` : `sub_${lane}_${i}.png`;
          form.append(key, png, key);
          captions.push({
            file: key,
            start: win.start,
            end: Math.min(win.end, duration),
            ...(lane > 0 ? { lane } : {}),
          });
        }
      }
    }
    if (captions.length > 0) {
      const blank = document.createElement("canvas");
      blank.width = settings.width;
      blank.height = settings.height;
      const png = await new Promise<Blob>((resolve, reject) =>
        blank.toBlob((b) => (b ? resolve(b) : reject(new Error("Could not render captions."))), "image/png")
      );
      form.append("sub_blank.png", png, "sub_blank.png");
    }
  }

  form.append(
    "spec",
    JSON.stringify({
      projectId,
      target,
      ...settings,
      duration,
      fadeIn: doc.fadeIn ?? 0,
      fadeOut: doc.fadeOut ?? 0,
      clips,
      audio,
      overlayVideos,
      overlays,
      captions,
    })
  );
  return form;
}

/** Poll an export job to completion, reporting progress. Returns the file name. */
export async function pollExport(
  jobId: string,
  onProgress: (stage: string, ratio: number) => void,
  isCanceled: () => boolean = () => false
): Promise<string> {
  for (;;) {
    if (isCanceled()) throw new Error("Export canceled.");
    await new Promise((r) => setTimeout(r, 400));
    const st = await apiFetch(`/api/cut/export/${jobId}`);
    const status = await apiJson<{
      status?: string;
      progress?: number;
      outName?: string;
    }>(st);
    if (!st.ok || status.status === "error") throw new Error(status.error ?? "Export failed.");
    onProgress("Rendering", status.progress ?? 0);
    if (status.status === "done") return status.outName ?? "export.mp4";
  }
}

/** Trigger a browser download of a finished export by job id. */
export function downloadExport(jobId: string, outName: string) {
  const a = document.createElement("a");
  a.href = apiUrl(`/api/cut/export/${jobId}/file`);
  a.download = outName;
  document.body.appendChild(a);
  a.click();
  a.remove();
}

/** Build the cut and hand it to the engine, returning the new job id. Progress,
 * cancel, download, and the finished-file actions are all driven from the
 * engine's job feed by the exports dock — this only kicks the render off, so it
 * returns the moment the job is queued and never blocks on the encode. */
export async function createExportJob(
  projectId: string,
  doc: ExportDoc,
  settings: ExportSettings
): Promise<string> {
  const form = await buildExportForm(projectId, doc, settings, "export");
  const res = await apiFetch("/api/cut/export", { method: "POST", body: form });
  const body = await apiJson<{ id?: string }>(res);
  if (!res.ok || !body.id) throw new Error(body.error ?? "Export failed to start.");
  return body.id;
}

/** Cancel a running or queued export job by id. */
export function cancelExportJob(jobId: string) {
  void apiFetch(`/api/cut/export/${jobId}`, { method: "DELETE" }).catch(() => {});
}

/** Low-res proxy of the actual edit for the project card's hover preview.
 * Renders through the same pipeline (overlays and all), writing the project's
 * preview.mp4. Best-effort: silently no-ops if a slot is busy or there's no
 * footage yet. */
export async function renderPreviewProxy(projectId: string, doc: ExportDoc, aspect: Aspect) {
  const [width, height] = aspect === "16:9" ? [640, 360] : [360, 640];
  const settings: ExportSettings = { width, height, fps: 24, crf: 30, preset: "veryfast" };
  let form: FormData;
  try {
    form = await buildExportForm(projectId, doc, settings, "preview");
  } catch {
    return; // no clips yet
  }
  const res = await apiFetch("/api/cut/export", { method: "POST", body: form });
  const body = (await res.json().catch(() => ({}))) as { id?: string };
  if (!res.ok || !body.id) return; // a slot was busy; try again later
  await pollExport(body.id, () => {}).catch(() => {});
}
