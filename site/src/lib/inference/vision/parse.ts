import { z } from "zod";

import { InferenceProviderError } from "@/lib/inference/providers";
import type {
  VisionElement,
  VisionParseOptions,
} from "@/lib/inference/vision/schema";

type FetchImpl = typeof fetch;

// Read RunPod config at module load so a missing var fails the deploy, not the
// first request.
//
// RUNPOD_VISION_BASE_URL lets you point the worker somewhere other than RunPod
// Cloud — e.g. a local CPU worker at http://localhost:8000 (see
// vision/docker-compose.yml). When it's set we POST `${base}/runsync` and the
// API key / endpoint ID become optional, since the local RunPod API server
// doesn't authenticate. When it's unset we fall back to RunPod Cloud and both
// of those vars are required.
const baseUrlOverride = process.env.RUNPOD_VISION_BASE_URL?.trim();
const apiKey = baseUrlOverride ? (process.env.RUNPOD_API_KEY?.trim() ?? "") : requireEnv("RUNPOD_API_KEY");
const endpointId = baseUrlOverride ? "" : requireEnv("RUNPOD_VISION_ENDPOINT_ID");
const runsyncUrl = baseUrlOverride
  ? `${baseUrlOverride.replace(/\/+$/, "")}/runsync`
  : `https://api.runpod.ai/v2/${endpointId}/runsync`;

function requireEnv(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(`${name} must be set to use the vision API.`);
  }
  return value;
}

const defaultBoxThreshold = 0.05;
const defaultIouThreshold = 0.1;
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
    const headers: Record<string, string> = { "Content-Type": "application/json" };
    // A local worker (RUNPOD_VISION_BASE_URL) needs no auth; only send the
    // bearer token when we actually have one (i.e. talking to RunPod Cloud).
    if (apiKey) {
      headers.Authorization = `Bearer ${apiKey}`;
    }
    response = await fetchImpl(runsyncUrl, {
      method: "POST",
      headers,
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
