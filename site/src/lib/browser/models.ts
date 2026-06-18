// Central registry of Browser Use Cloud model IDs (mirrors gemini-models.ts).
//
// Browser Use exposes its own model catalog (BuModel); pin the one we run here
// so bumping it is a one-line change. Its SDK default is the most expensive Opus
// tier, so we choose a fast, cost-effective model explicitly.
export const browserUseModels = {
  agent: "gemini-3-flash",
} as const;

export type BrowserUseModel =
  (typeof browserUseModels)[keyof typeof browserUseModels];
