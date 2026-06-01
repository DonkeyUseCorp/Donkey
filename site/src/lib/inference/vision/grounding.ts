import { GoogleGenAI, Type } from "@google/genai";
import { z } from "zod";

import { ensureConfigured } from "@/lib/inference/http";
import { InferenceProviderError } from "@/lib/inference/providers";
import { geminiClientConfig } from "@/lib/inference/screenshot-parsing/gemini-flash";
import type {
  VisionElement,
  VisionModel,
  VisionTarget,
} from "@/lib/inference/vision/schema";

export type GroundingResult = {
  target: VisionTarget | null;
  alternates: VisionTarget[];
};

const groundingOutputSchema = z.object({
  elementId: z.string(),
  confidence: z.number().min(0).max(1).optional().default(0.5),
  alternates: z.array(z.object({
    elementId: z.string(),
    confidence: z.number().min(0).max(1).optional().default(0.5),
  })).optional().default([]),
});

const geminiResponseSchema = {
  type: Type.OBJECT,
  required: ["elementId", "confidence"],
  properties: {
    elementId: {
      type: Type.STRING,
      description: "id of the single best-matching element, or empty string if none match.",
    },
    confidence: { type: Type.NUMBER },
    alternates: {
      type: Type.ARRAY,
      items: {
        type: Type.OBJECT,
        required: ["elementId", "confidence"],
        properties: {
          elementId: { type: Type.STRING },
          confidence: { type: Type.NUMBER },
        },
      },
    },
  },
};

// Resolve a natural-language instruction to a click target by letting the model
// pick from the already-parsed elements (text only — no image). Coordinates
// always come from the parser, never the model.
export async function groundInstruction(
  elements: VisionElement[],
  instruction: string,
  model: VisionModel,
): Promise<GroundingResult> {
  const config = geminiClientConfig();
  ensureConfigured(config.configured, "Grounding model credentials are not configured.");

  const byID = new Map(elements.map((element) => [element.id, element]));

  const client = new GoogleGenAI(config.options);
  let rawResponse: { text?: string };
  try {
    rawResponse = await client.models.generateContent({
      model,
      contents: groundingPrompt(elements, instruction),
      config: {
        responseMimeType: "application/json",
        responseSchema: geminiResponseSchema,
        temperature: 0,
      },
    });
  } catch (error) {
    throw new InferenceProviderError("Grounding request failed.", {
      statusCode: 502,
      code: "provider_error",
      details: { message: error instanceof Error ? error.message : String(error) },
    });
  }

  const parsed = groundingOutputSchema.safeParse(safeJsonParse(rawResponse.text));
  if (!parsed.success) {
    return { target: null, alternates: [] };
  }

  const target = targetFor(byID, parsed.data.elementId, parsed.data.confidence);
  const alternates = parsed.data.alternates
    .map((alternate) => targetFor(byID, alternate.elementId, alternate.confidence))
    .filter((value): value is VisionTarget => value !== null);

  return { target, alternates };
}

function groundingPrompt(elements: VisionElement[], instruction: string): string {
  const catalog = elements.map((element) => ({
    id: element.id,
    label: element.label,
    kind: element.kind,
    interactive: element.interactive,
  }));
  return [
    "You select the single UI element that best satisfies a user instruction.",
    "You are given a JSON list of detected on-screen elements.",
    "Return the id of the best-matching element, or an empty string if none match.",
    "Optionally include a few ranked alternates.",
    "",
    `Instruction: ${instruction}`,
    "",
    `Elements: ${JSON.stringify(catalog)}`,
  ].join("\n");
}

function targetFor(
  byID: Map<string, VisionElement>,
  elementId: string,
  confidence: number,
): VisionTarget | null {
  const element = byID.get(elementId.trim());
  if (!element) {
    return null;
  }
  return {
    elementId: element.id,
    label: element.label,
    kind: element.kind,
    box: element.box,
    point: element.point,
    confidence,
  };
}

function safeJsonParse(text: string | undefined): unknown {
  if (!text) {
    return null;
  }
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}
