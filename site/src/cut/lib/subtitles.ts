import { formatTime } from "./time";
import type { SubtitleCue, TextOverlay } from "./types";

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

/** A cue as a synthetic overlay, so captions ride the title pipeline. */
export function cueOverlay(cue: SubtitleCue): TextOverlay {
  return { id: `sub-${cue.id}`, text: wrapCaption(cue.text), start: cue.start, end: cue.end, ...SUB_STYLE };
}

/** The cue under a given time, if any. */
export function cueAt(cues: SubtitleCue[], t: number): SubtitleCue | undefined {
  return cues.find((c) => t >= c.start && t < c.end);
}

/** Compact panel timestamp (m:ss.s) — the same convention as the transport
 * readout, so a cue and the playhead never show different times for one
 * instant, and a rounded 59.97s can't render as an invalid ":60". */
export const fmtCueTime = formatTime;
