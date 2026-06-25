// Central registry of OpenAI model IDs the gateway runs (mirrors gemini-models.ts).
// Anything the code selects lives here so it is priced exhaustively in provider-pricing.ts;
// bumping a model is a one-line change here.
export const openaiModels = {
  // Developer UI inspection Responses calls.
  debugInspection: "gpt-5.4",
} as const;

export type OpenAIRunModel = (typeof openaiModels)[keyof typeof openaiModels];
