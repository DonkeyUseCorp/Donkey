export type AssetType = "video" | "audio";

/** Project output frame. Vertical (TikTok/Reels) or widescreen (YouTube). */
export type Aspect = "9:16" | "16:9";

export const FRAME: Record<Aspect, { w: number; h: number }> = {
  "9:16": { w: 1080, h: 1920 },
  "16:9": { w: 1920, h: 1080 },
};

export const ASPECT_LABEL: Record<Aspect, string> = {
  "9:16": "Vertical · 9:16",
  "16:9": "Widescreen · 16:9",
};

/** Asset fields persisted in project.json. */
export interface StoredAsset {
  id: string;
  fileName: string; // file inside the project's media/ folder
  name: string; // original display name
  type: AssetType;
  duration: number; // seconds
  width?: number;
  height?: number;
}

/** Runtime asset: stored fields plus derived/browser-only data. */
export interface MediaAsset extends StoredAsset {
  url: string; // /api/projects/<id>/media/<fileName>
  /** Filmstrip frames (video only), evenly spaced every `thumbStep` seconds. */
  thumbs?: string[];
  thumbStep?: number;
  /** Normalized waveform peaks 0..1 (audio only). */
  peaks?: number[];
}

/** A clip on the magnetic video track. Order in the array is timeline order. */
export interface VideoClip {
  id: string;
  assetId: string;
  in: number; // trim-in inside the source, seconds
  out: number; // trim-out inside the source, seconds
  muted: boolean;
  /** How the clip meets the 9:16 frame: letterboxed ("fit", default) or
   * scaled to cover it ("fill", cropping the overflow). */
  fit?: "fit" | "fill";
  /** Crop-window pan in fill mode, -1..1 per axis (0 = centered): which part
   * of the oversized video stays visible. */
  panX?: number;
  panY?: number;
}

/** A clip on the free-form soundtrack track. */
export interface AudioClip {
  id: string;
  assetId: string;
  start: number; // timeline position, seconds
  in: number;
  out: number;
  volume: number; // 0..1.5
  fadeIn?: number; // seconds, ramp up from the clip start
  fadeOut?: number; // seconds, ramp down into the clip end
}

export type FontId = "sf" | "serif" | "rounded" | "mono" | "impact";

export interface FontDef {
  id: FontId;
  label: string;
  stack: string;
}

export const FONTS: FontDef[] = [
  { id: "sf", label: "SF Pro", stack: '-apple-system, "SF Pro Display", "Helvetica Neue", Helvetica, Arial, sans-serif' },
  { id: "serif", label: "New York", stack: '"New York", ui-serif, Georgia, "Times New Roman", serif' },
  { id: "rounded", label: "Rounded", stack: 'ui-rounded, "SF Pro Rounded", "Arial Rounded MT Bold", "Helvetica Neue", sans-serif' },
  { id: "mono", label: "Mono", stack: 'ui-monospace, "SF Mono", Menlo, "Courier New", monospace' },
  { id: "impact", label: "Impact", stack: 'Impact, "Arial Black", "Helvetica Neue", sans-serif' },
];

export const fontStack = (id: FontId) =>
  FONTS.find((f) => f.id === id)?.stack ?? FONTS[0].stack;

export interface TextOverlay {
  id: string;
  text: string;
  start: number; // timeline seconds
  end: number;
  x: number; // center, fraction of frame width 0..1
  y: number; // center, fraction of frame height 0..1
  size: number; // px at a 1080-wide frame
  font: FontId;
  weight: 400 | 700;
  color: string;
  shadow: boolean;
  plate: boolean; // translucent rounded plate behind the text
  plateRadius?: number; // plate corner radius in em (default PLATE_RADIUS)
}

/** One subtitle caption, timed against the timeline (not the source files). */
export interface SubtitleCue {
  id: string;
  start: number; // timeline seconds
  end: number;
  text: string;
  /** Word timings from the transcriber; dropped once the text is hand-edited
   * (they no longer match), which falls back to proportional splitting. */
  words?: { t0: number; t1: number; w: string }[];
}

export interface SubtitlesBlock {
  cues: SubtitleCue[];
  /** Render captions on the preview and burn them into exports. */
  showOnVideo: boolean;
  /** Show the cue track on the timeline. */
  showOnTimeline: boolean;
  locale?: string;
  generatedAt?: number;
}

export const emptySubtitles = (): SubtitlesBlock => ({
  cues: [],
  showOnVideo: true,
  showOnTimeline: true,
});

export type Selection =
  | { kind: "clip"; id: string }
  | { kind: "audio"; id: string }
  | { kind: "text"; id: string }
  | null;

export interface ClipSpan {
  clip: VideoClip;
  asset: MediaAsset;
  start: number; // timeline start
  len: number;
}

/** The document persisted as project.json inside each project folder. */
export interface ProjectDoc {
  version: 1;
  name: string;
  createdAt: number;
  updatedAt: number;
  assets: StoredAsset[];
  clips: VideoClip[];
  audioClips: AudioClip[];
  overlays: TextOverlay[];
  /** Output frame; absent in older projects (which are all 9:16). */
  aspect?: Aspect;
  /** Auto-generated (then hand-edited) subtitles. */
  subtitles?: SubtitlesBlock;
  /** Legacy per-project view metadata — view state now lives in IndexedDB;
   * still read on open so older project.json files keep their zoom. */
  ui?: {
    pxPerSec?: number;
  };
  /** TikTok publishing metadata, prepared here and copied over on upload. */
  publish?: {
    caption?: string;
    tags?: string;
    soundTitle?: string;
    handle?: string;
  };
}

export interface ProjectSummary {
  id: string;
  name: string;
  createdAt: number;
  updatedAt: number;
  duration: number;
  clipCount: number;
  assetCount: number;
  /** Media file used for the card poster / hover preview. */
  previewFile?: string;
}

export const mediaUrl = (projectId: string, fileName: string) =>
  `/api/projects/${projectId}/media/${encodeURIComponent(fileName)}`;
