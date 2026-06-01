import { NextResponse } from "next/server";

import {
  creditUsageHeaders,
  inferenceUsageRoutes,
  recordFailedInferenceUsage,
  recordInferenceUsage,
  requireInferenceCredits,
} from "@/lib/credits/inference";
import { withDonkeyAuth } from "@/lib/donkey-api-auth";
import { InferenceProviderError } from "@/lib/inference/providers";
import {
  checkInMemoryRateLimit,
  rateLimitResponse,
} from "@/lib/inference/rate-limit";
import { readLimitedJsonBody } from "@/lib/inference/request-body";
import {
  inferenceErrorCode,
  inferenceProviderErrorResponse,
  requireInferenceClientId,
  validationErrorResponse,
} from "@/lib/inference/responses";
import { groundInstruction } from "@/lib/inference/vision/grounding";
import { parseImage } from "@/lib/inference/vision/parse";
import {
  visionRequestSchema,
  type VisionResponse,
} from "@/lib/inference/vision/schema";

export const dynamic = "force-dynamic";

const visionMaxBodyBytes = 6_250_000;
const visionRateLimit = {
  limit: 4,
  windowMs: 3_000,
};
const inferenceProvider = "omniparser";
const parseModel = "omniparser-v2";

// B2B vision API: parse a screenshot into UI elements, and optionally ground a
// natural-language instruction to a click target. Single-shot only.
export const POST = withDonkeyAuth(async (request) => {
  const client = requireInferenceClientId(request.donkey.clientId);
  if (!client.ok) {
    return client.response;
  }

  const rateLimit = checkInMemoryRateLimit({
    key: `${request.donkey.userId}:${client.clientId}`,
    ...visionRateLimit,
  });
  if (!rateLimit.ok) {
    return rateLimitResponse(rateLimit.retryAfterSeconds);
  }

  const body = await readLimitedJsonBody(request, visionMaxBodyBytes);
  if (!body.ok) {
    return body.response;
  }

  const parsed = visionRequestSchema.safeParse(body.json);
  if (!parsed.success) {
    return validationErrorResponse(parsed.error);
  }
  const { image, instruction, model, returnElements, options } = parsed.data;
  const billedModel = instruction ? model : parseModel;

  const credits = await requireInferenceCredits({
    model: billedModel,
    provider: inferenceProvider,
    route: inferenceUsageRoutes.vision,
    userId: request.donkey.userId,
  });
  if (!credits.ok) {
    return credits.response;
  }

  try {
    const parseResult = await parseImage(image, options);

    const grounding = instruction
      ? await groundInstruction(parseResult.elements, instruction, model)
      : null;

    const includeElements = returnElements ?? instruction === undefined;
    const result: VisionResponse = {
      image: parseResult.image,
      ...(includeElements ? { elements: parseResult.elements } : {}),
      ...(grounding
        ? { target: grounding.target, alternates: grounding.alternates, model }
        : {}),
    };

    const recordedUsage = await recordInferenceUsage({
      clientId: client.clientId,
      metadata: { grounded: String(instruction !== undefined) },
      model: billedModel,
      provider: inferenceProvider,
      requestKind: "vision_parse",
      route: inferenceUsageRoutes.vision,
      status: "succeeded",
      userId: request.donkey.userId,
    });

    return NextResponse.json(result, {
      headers: creditUsageHeaders(recordedUsage),
    });
  } catch (error) {
    await recordFailedInferenceUsage({
      clientId: client.clientId,
      errorCode: inferenceErrorCode(error),
      metadata: { grounded: String(instruction !== undefined) },
      model: billedModel,
      provider: inferenceProvider,
      requestKind: "vision_parse",
      route: inferenceUsageRoutes.vision,
      userId: request.donkey.userId,
    });
    if (error instanceof InferenceProviderError) {
      return inferenceProviderErrorResponse(error);
    }

    throw error;
  }
});
