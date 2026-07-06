import { formatTime } from "./time";
import type { FontId, SubtitleCue, TextOverlay } from "./types";

/** Caption look shared by the preview layer and the export burn-in —
 * TikTok-style bold white on a translucent plate, low center. */
export const SUB_STYLE = {
  x: 0.5,
  y: 0.8,
  size: 42,
  font: "sf",
  weight: 700,
  color: "#FFFFFF",
  shadow: true,
  plate: true,
} as const;

export type CaptionStyleId = "clean" | "hook" | "punchy";

/** A caption preset: the shared subtitle look plus optional opener emphasis
 * (a bigger, punchier first line). */
export interface CaptionStyle {
  id: CaptionStyleId;
  label: string;
  x: number;
  y: number;
  size: number;
  font: FontId;
  weight: 400 | 700;
  color: string;
  shadow: boolean;
  plate: boolean;
  plateColor?: string;
  plateOpacity?: number;
  /** Multiply the opening cue's size, so the hook lands bigger. */
  openerScale?: number;
}

export const CAPTION_STYLES: Record<CaptionStyleId, CaptionStyle> = {
  clean: {
    id: "clean",
    label: "Clean",
    x: 0.5,
    y: 0.8,
    size: 42,
    font: "sf",
    weight: 700,
    color: "#FFFFFF",
    shadow: true,
    plate: true,
  },
  hook: {
    id: "hook",
    label: "Curiosity hook",
    x: 0.5,
    y: 0.78,
    size: 46,
    font: "rounded",
    weight: 700,
    color: "#FFFFFF",
    shadow: true,
    plate: true,
    plateColor: "#0A84FF",
    plateOpacity: 0.9,
    openerScale: 1.28,
  },
  punchy: {
    id: "punchy",
    label: "Big & punchy",
    x: 0.5,
    y: 0.74,
    size: 50,
    font: "impact",
    weight: 700,
    color: "#FFE94A",
    shadow: true,
    plate: false,
    openerScale: 1.34,
  },
};

/** The active caption preset for a subtitles block. */
export function captionStyle(style: CaptionStyleId | undefined): CaptionStyle {
  return CAPTION_STYLES[style ?? "clean"] ?? CAPTION_STYLES.clean;
}

/** Balance a caption onto up to two lines so it never overflows the frame. */
export function wrapCaption(text: string): string {
  const t = text.trim().replace(/\s+/g, " ");
  if (t.length <= 26) return t;
  const mid = t.length / 2;
  let best = -1;
  for (let i = t.indexOf(" "); i !== -1; i = t.indexOf(" ", i + 1)) {
    if (best === -1 || Math.abs(i - mid) < Math.abs(best - mid)) best = i;
  }
  return best === -1 ? t : t.slice(0, best) + "\n" + t.slice(best + 1);
}

/**
 * Wrap a caption into as many lines as it takes to keep every line inside the
 * frame width at font `size`. The export burn-in renders each `\n`-separated
 * line centered without wrapping, so this is what guarantees captions stay in
 * bounds — bigger styles (and the punchy opener) wrap to fewer words per line.
 */
export function wrapCaptionForSize(text: string, size: number): string {
  const words = text.trim().replace(/\s+/g, " ").split(" ").filter(Boolean);
  if (words.length === 0) return "";
  // ~88% of the 1080 design short-side, with a conservative bold-glyph advance
  // (~0.58·size) so real fonts stay comfortably inside the safe area.
  const maxChars = Math.max(8, Math.floor((0.88 * 1080) / (0.58 * size)));
  const lines: string[] = [];
  let line = "";
  for (const w of words) {
    const cand = line ? `${line} ${w}` : w;
    if (line && cand.length > maxChars) {
      lines.push(line);
      line = w;
    } else {
      line = cand;
    }
  }
  if (line) lines.push(line);
  return lines.join("\n");
}

/** A cue as a synthetic overlay, so captions ride the title pipeline. The style
 * preset drives the look; the opening cue can render bigger for a punchy hook. */
export function cueOverlay(
  cue: SubtitleCue,
  style: CaptionStyle = CAPTION_STYLES.clean,
  isOpener = false
): TextOverlay {
  const size = Math.round(style.size * (isOpener && style.openerScale ? style.openerScale : 1));
  return {
    id: `sub-${cue.id}`,
    text: wrapCaptionForSize(cue.text, size),
    start: cue.start,
    end: cue.end,
    x: style.x,
    y: style.y,
    size,
    font: style.font,
    weight: style.weight,
    color: style.color,
    shadow: style.shadow,
    plate: style.plate,
    ...(style.plateColor ? { plateColor: style.plateColor } : {}),
    ...(style.plateOpacity !== undefined ? { plateOpacity: style.plateOpacity } : {}),
  };
}

/** The cue under a given time, if any. */
export function cueAt(cues: SubtitleCue[], t: number): SubtitleCue | undefined {
  return cues.find((c) => t >= c.start && t < c.end);
}

/** Compact panel timestamp (m:ss.s) — the same convention as the transport
 * readout, so a cue and the playhead never show different times for one
 * instant, and a rounded 59.97s can't render as an invalid ":60". */
export const fmtCueTime = formatTime;
