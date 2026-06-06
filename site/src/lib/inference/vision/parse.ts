import { z } from "zod";

import { InferenceProviderError } from "@/lib/inference/providers";
import type {
  VisionElement,
  VisionParseOptions,
} from "@/lib/inference/vision/schema";

type FetchImpl = typeof fetch;

// Read RunPod config at module load so a missing var fails the deploy, not the
// first request.
const apiKey = requireEnv("RUNPOD_API_KEY");
const endpointId = requireEnv("RUNPOD_VISION_ENDPOINT_ID");

function requireEnv(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(`${name} must be set to use the vision API.`);
  }
  return value;
}

const defaultBoxThreshold = 0.05;
// 0.7 keeps adjacent/dense boxes (e.g. file-list rows) distinct; a low value
// over-merges neighbors. Matches the worker default in vision/handler.py.
const defaultIouThreshold = 0.7;
const defaultImgsz = 640;

// Raw worker output. bbox is [x1, y1, x2, y2] in ratio space (0-1).
const workerElementSchema = z.object({
  type: z.string().optional(),
  bbox: z.tuple([z.number(), z.number(), z.number(), z.number()]),
  interactivity: z.boolean().optional(),
  content: z.string().nullable().optional(),
});

const workerOutputSchema = z.object({
  image_size: z.object({ width: z.number().positive(), height: z.number().positive() }),
  parsed_content_list: z.array(workerElementSchema).default([]),
});

const runpodResponseSchema = z.object({
  status: z.string().optional(),
  error: z.unknown().optional(),
  output: z.unknown().optional(),
});

export type VisionParseResult = {
  image: { width: number; height: number };
  elements: VisionElement[];
};

export async function parseImage(
  imageBase64: string,
  options: VisionParseOptions = {},
  fetchImpl: FetchImpl = fetch,
): Promise<VisionParseResult> {
  const rawOutput = await callWorker(imageBase64, options, fetchImpl);
  const parsed = workerOutputSchema.safeParse(rawOutput);
  if (!parsed.success) {
    throw new InferenceProviderError("Vision worker output was malformed.", {
      statusCode: 502,
      code: "provider_error",
    });
  }

  const { width, height } = parsed.data.image_size;
  const usedIDs = new Set<string>();
  const elements: VisionElement[] = [];

  for (const element of parsed.data.parsed_content_list) {
    const [x1, y1, x2, y2] = element.bbox;
    // Drop degenerate boxes; they carry no usable geometry.
    if (x2 <= x1 || y2 <= y1) {
      continue;
    }

    const boxX = x1 * width;
    const boxY = y1 * height;
    const boxW = (x2 - x1) * width;
    const boxH = (y2 - y1) * height;
    const content = element.content?.trim() ?? "";
    const interactive = element.interactivity ?? false;

    elements.push({
      id: uniqueShortID(usedIDs),
      label: content || element.type || "element",
      kind: interactive ? "button" : element.type === "text" ? "text" : "icon",
      interactive,
      box: { x: boxX, y: boxY, width: boxW, height: boxH },
      point: { x: boxX + boxW / 2, y: boxY + boxH / 2 },
      confidence: 0.5,
    });
  }

  return { image: { width, height }, elements };
}

async function callWorker(
  imageBase64: string,
  options: VisionParseOptions,
  fetchImpl: FetchImpl,
): Promise<unknown> {
  let response: Response;
  try {
    response = await fetchImpl(`https://api.runpod.ai/v2/${endpointId}/runsync`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        input: {
          image: imageBase64,
          box_threshold: options.boxThreshold ?? defaultBoxThreshold,
          iou_threshold: options.iouThreshold ?? defaultIouThreshold,
          imgsz: defaultImgsz,
        },
      }),
    });
  } catch (error) {
    throw new InferenceProviderError("Vision worker request failed.", {
      statusCode: 502,
      code: "provider_request_failed",
      details: { message: error instanceof Error ? error.message : String(error) },
    });
  }

  if (!response.ok) {
    throw new InferenceProviderError(`Vision worker returned HTTP ${response.status}.`, {
      statusCode: 502,
      code: "provider_error",
      details: { httpStatus: response.status },
    });
  }

  const body = runpodResponseSchema.safeParse(await response.json());
  if (!body.success) {
    throw new InferenceProviderError("Vision worker response was malformed.", {
      statusCode: 502,
      code: "provider_error",
    });
  }

  const { status, output, error } = body.data;
  if (status && status !== "COMPLETED") {
    throw new InferenceProviderError(`Vision worker job did not complete (status ${status}).`, {
      statusCode: 502,
      code: "provider_error",
      details: typeof error === "string" ? { error } : undefined,
    });
  }

  return output;
}

function uniqueShortID(used: Set<string>): string {
  let id = shortID();
  while (used.has(id)) {
    id = shortID();
  }
  used.add(id);
  return id;
}

function shortID(): string {
  return Math.random().toString(36).slice(2, 8).padEnd(6, "0");
}
