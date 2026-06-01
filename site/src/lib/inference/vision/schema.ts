import { z } from "zod";

// Public B2B vision API contract for POST /api/inference/vision.
//
// Two stages: parse a screenshot into UI elements (always), and optionally
// ground a natural-language instruction ("click the play button") to a click
// target using an LLM. Coordinates are pixels relative to the uploaded image,
// origin top-left.

// Allow-list of grounding models. Extend deliberately — each must be wired in
// vision/grounding.ts.
export const supportedVisionModels = ["gemini-2.5-flash"] as const;
export type VisionModel = (typeof supportedVisionModels)[number];
export const defaultVisionModel: VisionModel = "gemini-2.5-flash";

export const visionParseOptionsSchema = z.object({
  boxThreshold: z.number().min(0).max(1).optional(),
  iouThreshold: z.number().min(0).max(1).optional(),
});

export type VisionParseOptions = z.infer<typeof visionParseOptionsSchema>;

export const visionRequestSchema = z.object({
  // Base64-encoded screenshot (png/jpeg/webp), no data: prefix.
  image: z.string().min(1).max(6_000_000),
  // When present, the LLM grounding stage runs and a target is returned.
  instruction: z.string().min(1).max(2_000).optional(),
  // Grounding model; only used when instruction is present.
  model: z.enum(supportedVisionModels).default(defaultVisionModel),
  // Whether to include the full parsed element list in the response. Defaults
  // to true for parse-only requests and false when an instruction is grounded.
  returnElements: z.boolean().optional(),
  options: visionParseOptionsSchema.optional().default({}),
});

export type VisionRequest = z.infer<typeof visionRequestSchema>;

export type VisionPoint = { x: number; y: number };
export type VisionBox = { x: number; y: number; width: number; height: number };

export type VisionElement = {
  id: string;
  label: string;
  kind: string;
  interactive: boolean;
  box: VisionBox;
  point: VisionPoint;
  confidence: number;
};

export type VisionTarget = {
  elementId: string;
  label: string;
  kind: string;
  box: VisionBox;
  point: VisionPoint;
  confidence: number;
};

export type VisionResponse = {
  image: { width: number; height: number };
  // Present unless explicitly suppressed via returnElements: false.
  elements?: VisionElement[];
  // Present only when an instruction was grounded.
  target?: VisionTarget | null;
  alternates?: VisionTarget[];
  model?: VisionModel;
};
