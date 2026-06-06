import { NextResponse } from "next/server";

import {
  creditUsageHeaders,
  inferenceUsageRoutes,
  recordFailedInferenceUsage,
  recordInferenceUsage,
  requireInferenceCredits,
} from "@/lib/credits/inference";
import {
  getActiveVisionSubscription,
  releaseVisionApiCall,
  reserveVisionApiCall,
} from "@/lib/billing/vision-subscription";
import {
  type DonkeyAuthenticatedRequest,
  shouldBypassDonkeyInferenceCredits,
  unauthorizedResponse,
  withDonkeyAuth,
} from "@/lib/donkey-api-auth";
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
// Third-party API keys are capped at 3 requests/second (the monthly call quota
// is the real spend cap; this is a burst guard).
const visionApiKeyRateLimit = {
  limit: 3,
  windowMs: 1_000,
};
const inferenceProvider = "omniparser";
const parseModel = "omniparser-v2";

// This route accepts third-party API keys in addition to app sessions.
export const POST = withDonkeyAuth(visionParseHandler, { allowApiKey: true });

// B2B vision API: parse a screenshot into UI elements, and optionally ground a
// natural-language instruction to a click target. Single-shot only.
//
// Two auth paths share this handler:
//   - api-key: third-party developers, gated by an active Vision API
//     subscription + monthly call quota (no money-credit charge).
//   - session-cookie / dev-bypass: the Mac app, gated by the credit balance.
async function visionParseHandler(request: DonkeyAuthenticatedRequest) {
  const isApiKey = request.donkey.method === "api-key";

  const client = requireInferenceClientId(request.donkey.clientId);
  if (!client.ok) {
    return client.response;
  }

  // Bucket API-key callers by their key id, not the client-supplied
  // x-donkey-client-id header — otherwise a caller could rotate the header to
  // get a fresh burst bucket per request and defeat the limit.
  const rateLimitKey = isApiKey
    ? `apikey:${request.donkey.apiKeyId}`
    : `${request.donkey.userId}:${client.clientId}`;
  const rateLimit = checkInMemoryRateLimit({
    key: rateLimitKey,
    ...(isApiKey ? visionApiKeyRateLimit : visionRateLimit),
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

  // The dev-bypass user has no real account, so skip the credit preflight and
  // usage recording (both reference a real user row) when bypassing auth.
  const bypassCredits = shouldBypassDonkeyInferenceCredits(request.donkey);
  // For the api-key path, the reserved quota call is released if the request
  // later fails, so a failed parse doesn't burn the developer's quota.
  let apiKeyQuota: { limit: number; remaining: number } | null = null;
  if (isApiKey) {
    const subscription = await getActiveVisionSubscription(request.donkey.userId);
    if (!subscription) {
      return unauthorizedResponse();
    }
    const reservation = await reserveVisionApiCall({
      monthlyCallQuota: subscription.monthlyCallQuota,
      userId: request.donkey.userId,
    });
    if (!reservation.ok) {
      // Operational limit, not an auth failure — keep it distinct so API
      // clients can tell "out of quota" apart from a bad key.
      return NextResponse.json(
        { error: "quota_exceeded", limit: subscription.monthlyCallQuota },
        { status: 402 },
      );
    }
    apiKeyQuota = {
      limit: subscription.monthlyCallQuota,
      remaining: reservation.remaining,
    };
  } else if (!bypassCredits) {
    const credits = await requireInferenceCredits({
      model: billedModel,
      provider: inferenceProvider,
      route: inferenceUsageRoutes.vision,
      userId: request.donkey.userId,
    });
    if (!credits.ok) {
      return credits.response;
    }
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

    let usageHeaders: Record<string, string> = {};
    if (bypassCredits) {
      usageHeaders["X-Donkey-Dev-Auth-Bypass"] = "true";
    } else {
      const recordedUsage = await recordInferenceUsage({
        billingMode: isApiKey ? "included" : "credits",
        clientId: client.clientId,
        metadata: { grounded: String(instruction !== undefined) },
        model: billedModel,
        provider: inferenceProvider,
        requestKind: "vision_parse",
        route: inferenceUsageRoutes.vision,
        status: "succeeded",
        userId: request.donkey.userId,
      });
      usageHeaders = apiKeyQuota
        ? {
            "X-Donkey-Calls-Limit": String(apiKeyQuota.limit),
            "X-Donkey-Calls-Remaining": String(apiKeyQuota.remaining),
          }
        : creditUsageHeaders(recordedUsage);
    }

    return NextResponse.json(result, {
      headers: usageHeaders,
    });
  } catch (error) {
    // Give the reserved quota call back — a failed parse shouldn't be billed.
    if (apiKeyQuota) {
      await releaseVisionApiCall(request.donkey.userId);
    }
    if (!bypassCredits) {
      await recordFailedInferenceUsage({
        billingMode: isApiKey ? "included" : "credits",
        clientId: client.clientId,
        errorCode: inferenceErrorCode(error),
        metadata: { grounded: String(instruction !== undefined) },
        model: billedModel,
        provider: inferenceProvider,
        requestKind: "vision_parse",
        route: inferenceUsageRoutes.vision,
        userId: request.donkey.userId,
      });
    }
    if (error instanceof InferenceProviderError) {
      return inferenceProviderErrorResponse(error);
    }

    throw error;
  }
}
