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
  flashComputerUse: "gemini-3-flash-preview",
  // Generative image editing/generation ("nano banana"). Bump here when adopting a
  // newer image model; the backend also honors a GEMINI_IMAGE_MODEL override.
  flashImage: "gemini-2.5-flash-image",
} as const;

export type GeminiModel = (typeof geminiModels)[keyof typeof geminiModels];

// Semantic roles map a job to the model we run for it. Prefer referencing a
// role over a bare constant so intent stays explicit at the call site.
export const geminiModelRoles = {
  // General chat and non-decision Responses calls — the latest full flash.
  chat: geminiModels.flash,
  // Fast structured task-intent and follow-up decisions.
  fastDecision: geminiModels.flashLite,
  // Browser Computer Use tool calls.
  browserComputerUse: geminiModels.flashComputerUse,
  // Screenshot parsing into read-only UI evidence.
  screenshotParse: geminiModels.flash,
  // Vision grounding: a cheap structured pick over already-parsed elements.
  visionGrounding: geminiModels.flashLite,
  // Generative image editing and generation.
  imageGeneration: geminiModels.flashImage,
} as const;
