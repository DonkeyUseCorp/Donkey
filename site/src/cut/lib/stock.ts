// The bundled stock catalogs: AI-generated stills and clips that ship with the
// site (files under public/cut-stock and public/cut-stock-video, manifests in
// stockManifest.ts and stockVideoManifest.ts). Each entry keeps the exact
// prompt that produced it — clicking a stock tile copies that prompt into the
// generate panel beside it for the user to edit and re-render on their account.
// Regenerate or extend the sets with `bun scripts/generate-stock-images.ts`
// and `bun scripts/generate-stock-videos.ts`.

export type StockAspect = "16:9" | "9:16" | "1:1";

export interface StockImage {
  id: string;
  category: StockCategory;
  /** The generation prompt, saved verbatim — the editable starting point. */
  prompt: string;
  /** Vision-extracted keywords for the visible content (objects, setting,
   * subjects) — what the search box matches beyond the prompt text. */
  tags: string[];
  aspect: StockAspect;
  /** Site-relative full-asset URL (under /cut-stock/) — lightbox, refs, timeline. */
  file: string;
  /** Small grid thumbnail URL for the browse panel. */
  thumb: string;
}

/** Veo renders landscape and portrait only — no square video. */
export type StockVideoAspect = "16:9" | "9:16";

export interface StockVideo {
  id: string;
  category: StockVideoCategory;
  /** The generation prompt, saved verbatim — the editable starting point. */
  prompt: string;
  /** Vision-extracted keywords for the visible content (objects, setting,
   * subjects) — what the search box matches beyond the prompt text. */
  tags: string[];
  aspect: StockVideoAspect;
  /** Site-relative mp4 URL (under /cut-stock-video/) — playback, refs, timeline. */
  file: string;
  /** Poster-frame thumbnail URL for the browse grid. */
  thumb: string;
  /** Rendered length in seconds. */
  duration: number;
}

export const STOCK_CATEGORIES = [
  "Business",
  "Nature",
  "Travel",
  "City",
  "Technology",
  "Anime",
  "Animal",
  "Food & Drink",
] as const;

export type StockCategory = (typeof STOCK_CATEGORIES)[number];

/** Video adds a catalog-only "Characters" section: talking-head clips whose
 * prompts carry an editable spoken line (Veo generates the dialogue audio). */
export const STOCK_VIDEO_CATEGORIES = ["Characters", ...STOCK_CATEGORIES] as const;

export type StockVideoCategory = (typeof STOCK_VIDEO_CATEGORIES)[number];

export const STOCK_ASPECT_LABEL: Record<StockAspect, string> = {
  "16:9": "Landscape (16:9)",
  "9:16": "Portrait (9:16)",
  "1:1": "Square (1:1)",
};
