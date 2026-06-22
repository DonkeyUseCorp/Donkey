// Central registry of ElevenLabs model IDs the gateway runs (mirrors gemini-models.ts).
// Models the code selects live here so they are priced exhaustively in provider-pricing.ts.
export const elevenLabsModels = {
  // Music composition.
  music: "music_v1",
} as const;

export type ElevenLabsRunModel = (typeof elevenLabsModels)[keyof typeof elevenLabsModels];
