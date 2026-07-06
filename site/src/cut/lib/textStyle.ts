import type { TextOverlay } from "./types";

// The style fields a title carries, minus its text/position/id/timing. Remembered
// across clips and projects so repeated titles share one look. Position and size
// stay at sensible defaults; only the visual style is reused.
export type TextStyle = Pick<
  TextOverlay,
  "size" | "font" | "weight" | "color" | "shadow" | "plate" | "plateColor" | "plateOpacity" | "plateRadius"
>;

const KEY = "cut-text-style";

export function readTextStyle(): Partial<TextStyle> {
  if (typeof localStorage === "undefined") return {};
  try {
    const v = JSON.parse(localStorage.getItem(KEY) ?? "{}") as unknown;
    return v && typeof v === "object" ? (v as Partial<TextStyle>) : {};
  } catch {
    return {};
  }
}

export function writeTextStyle(style: Partial<TextStyle>) {
  if (typeof localStorage === "undefined") return;
  try {
    localStorage.setItem(KEY, JSON.stringify(style));
  } catch {
    // Storage full/blocked — the style just won't persist.
  }
}
