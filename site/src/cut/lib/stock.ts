// The bundled stock-image catalog: AI-generated stills that ship with the site
// (files under public/cut-stock, manifest in stockManifest.ts). Each entry keeps
// the exact prompt that produced it — clicking a stock image copies that prompt
// into the generate flyover for the user to edit and re-render on their account.
// Regenerate or extend the set with `bun scripts/generate-stock-images.ts`.

export type StockAspect = "16:9" | "9:16" | "1:1";

export interface StockImage {
  id: string;
  category: StockCategory;
  /** The generation prompt, saved verbatim — the editable starting point. */
  prompt: string;
  aspect: StockAspect;
  /** Site-relative image URL (under /cut-stock/). */
  file: string;
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

export const STOCK_ASPECT_LABEL: Record<StockAspect, string> = {
  "16:9": "Landscape (16:9)",
  "9:16": "Portrait (9:16)",
  "1:1": "Square (1:1)",
};
