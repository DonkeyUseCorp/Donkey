// Central registry of Gemini model IDs used by the inference gateway.
//
// Model selection lives in code (see docs/guides/backend-apis.md), so this is
// the single source of truth for which Gemini models we run and what each one
// is for. Adapters and schemas should import these constants instead of
// hardcoding version strings, so bumping a model is a one-line change here.

// Canonical, dated-or-versioned model IDs. Add a new constant when adopting a
// new model; do not inline raw version strings at call sites.
export const geminiModels = {
  flash: "gemini-3.5-flash",
  flashLite: "gemini-3.1-flash-lite",
  // Generative image editing/generation ("nano banana"). Bump here when adopting a
  // newer image model.
  flashImage: "gemini-2.5-flash-image",
  // "Nano banana pro": higher-fidelity image editing/generation that takes a real
  // aspectRatio + imageSize (1K/2K/4K) via imageConfig. Gemini 3 preview models are
  // served only on Vertex's global endpoint, which our client already targets.
  proImage: "gemini-3-pro-image-preview",
} as const;

export type GeminiModel = (typeof geminiModels)[keyof typeof geminiModels];

// Generative text/image-to-video (Veo 3.1). Model selection lives in code, so the
// ids are hardcoded here rather than gated behind an env var — that keeps the
// feature on by default instead of silently dormant. Bump here when adopting a
// newer Veo.
export const veoModels = {
  // Best quality, slower, priciest per second.
  quality: "veo-3.1-generate-001",
  // Balanced speed/cost; the default when no tier is given.
  fast: "veo-3.1-fast-generate-001",
  // Cheapest and quickest, lower fidelity.
  lite: "veo-3.1-lite-generate-001",
} as const;

export type VeoModel = (typeof veoModels)[keyof typeof veoModels];

// Generative speech (Gemini TTS): text in, spoken audio out, with prompt-driven
// style direction and inline audio tags. Bump here when adopting a newer TTS model.
export const geminiTtsModels = {
  flash: "gemini-3.1-flash-tts-preview",
} as const;

export type GeminiTtsModel = (typeof geminiTtsModels)[keyof typeof geminiTtsModels];

// Maps the user-facing speed/quality tier (see the `video` SKILL.md picker) to a
// Veo model. An unknown/absent tier falls back to `fast` at the call site.
export const veoTierModels = {
  lite: veoModels.lite,
  fast: veoModels.fast,
  standard: veoModels.fast,
  high: veoModels.quality,
} as const;

// Semantic roles map a job to the model we run for it. Prefer referencing a
// role over a bare constant so intent stays explicit at the call site.
export const geminiModelRoles = {
  // General chat and non-decision Responses calls — the latest full flash.
  chat: geminiModels.flash,
  // Fast structured task-intent and follow-up decisions.
  fastDecision: geminiModels.flashLite,
  // Computer Use tool calls (browser and macOS desktop environments). Computer
  // use is a built-in tool of the main flash model, so both share one model.
  computerUse: geminiModels.flash,
  // Screenshot parsing into read-only UI evidence.
  screenshotParse: geminiModels.flash,
  // Vision grounding: a cheap structured pick over already-parsed elements.
  visionGrounding: geminiModels.flashLite,
  // Generative image editing and generation.
  imageGeneration: geminiModels.proImage,
} as const;
