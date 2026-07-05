"use client";

import { apiFetch, apiUrl } from "./api";
import { getClipSpans, totalDuration } from "./store";
import { cueOverlay } from "./subtitles";
import { renderOverlayPng } from "./textRender";
import type { Aspect, AudioClip, MediaAsset, SubtitlesBlock, TextOverlay, VideoClip } from "./types";

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

export interface ExportHandle {
  cancel: () => void;
  done: Promise<{ outName: string }>;
}

export function startExport(
  projectId: string,
  doc: {
    assets: MediaAsset[];
    clips: VideoClip[];
    audioClips: AudioClip[];
    overlays: TextOverlay[];
    subtitles: SubtitlesBlock;
  },
  settings: ExportSettings,
  onProgress: (stage: string, ratio: number) => void
): ExportHandle {
  let jobId: string | null = null;
  let canceled = false;

  const done = (async () => {
    const spans = getClipSpans(doc.clips, doc.assets);
    if (spans.length === 0) throw new Error("Add a video to the timeline first.");
    const duration = totalDuration(doc.clips);

    onProgress("Preparing", 0);
    const form = new FormData();
    const assetById = new Map(doc.assets.map((a) => [a.id, a]));

    // Media already lives in the project folder — the spec references it by
    // file name; only overlay PNGs travel with the request.
    const clips = spans.map((sp) => ({
      file: sp.asset.fileName,
      in: sp.clip.in,
      out: sp.clip.out,
      muted: sp.clip.muted,
      fit: sp.clip.fit ?? "fit",
      panX: sp.clip.panX ?? 0,
      panY: sp.clip.panY ?? 0,
    }));

    const audio = doc.audioClips
      .filter((a) => a.start < duration && assetById.has(a.assetId))
      .map((a) => ({
        file: assetById.get(a.assetId)!.fileName,
        in: a.in,
        out: a.out,
        start: a.start,
        volume: a.volume,
        fadeIn: a.fadeIn ?? 0,
        fadeOut: a.fadeOut ?? 0,
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

    // Subtitles burn in through the same overlay pipeline. When there are no
    // cues (no speech was found) nothing is added to the video.
    if (doc.subtitles.showOnVideo) {
      for (let i = 0; i < doc.subtitles.cues.length; i++) {
        const cue = doc.subtitles.cues[i];
        if (cue.start >= duration || !cue.text.trim()) continue;
        const png = await renderOverlayPng(cueOverlay(cue), settings.width, settings.height);
        const key = `sub_${i}.png`;
        form.append(key, png, key);
        overlays.push({ file: key, start: cue.start, end: Math.min(cue.end, duration) });
      }
    }

    form.append(
      "spec",
      JSON.stringify({ projectId, ...settings, duration, clips, audio, overlays })
    );

    onProgress("Starting encoder", 0);
    const res = await apiFetch("/api/cut/export", { method: "POST", body: form });
    const body = (await res.json()) as { id?: string; error?: string };
    if (!res.ok || !body.id) throw new Error(body.error ?? "Export failed to start.");
    jobId = body.id;

    let outName = "export.mp4";
    for (;;) {
      if (canceled) throw new Error("Export canceled.");
      await new Promise((r) => setTimeout(r, 400));
      const st = await apiFetch(`/api/cut/export/${jobId}`);
      const status = (await st.json()) as {
        status: string;
        progress: number;
        error?: string;
        outName?: string;
      };
      if (status.status === "error") throw new Error(status.error ?? "Export failed.");
      onProgress("Rendering", status.progress);
      if (status.status === "done") {
        outName = status.outName ?? outName;
        break;
      }
    }

    onProgress("Done", 1);
    const a = document.createElement("a");
    a.href = apiUrl(`/api/cut/export/${jobId}/file`);
    a.download = outName;
    document.body.appendChild(a);
    a.click();
    a.remove();
    return { outName };
  })();

  return {
    done,
    cancel: () => {
      canceled = true;
      if (jobId) void apiFetch(`/api/cut/export/${jobId}`, { method: "DELETE" });
    },
  };
}
