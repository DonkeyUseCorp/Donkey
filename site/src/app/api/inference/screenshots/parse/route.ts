import { NextResponse } from "next/server";

import {
  creditUsageHeaders,
  inferenceUsageRoutes,
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
  requireInferenceClientId,
  validationErrorResponse,
} from "@/lib/inference/responses";
import {
  parseScreenshot,
  screenshotParseModelForRequest,
} from "@/lib/inference/screenshot-parsing";
import { screenshotParseRequestSchema } from "@/lib/inference/screenshot-parsing/schema";

export const dynamic = "force-dynamic";

const screenshotParseMaxBodyBytes = 6_250_000;
const screenshotParseRateLimit = {
  limit: 4,
  windowMs: 3_000,
};

export const POST = withDonkeyAuth(async (request) => {
  const client = requireInferenceClientId(request.donkey.clientId);
  if (!client.ok) {
    return client.response;
  }

  const rateLimit = checkInMemoryRateLimit({
    key: `${request.donkey.userId}:${client.clientId}`,
    ...screenshotParseRateLimit,
  });
  if (!rateLimit.ok) {
    return rateLimitResponse(rateLimit.retryAfterSeconds);
  }

  const body = await readLimitedJsonBody(request, screenshotParseMaxBodyBytes);
  if (!body.ok) {
    return body.response;
  }

  const parsed = screenshotParseRequestSchema.safeParse(body.json);
  if (!parsed.success) {
    return validationErrorResponse(parsed.error);
  }
  if (parsed.data.metadata["screenshot.scope"] === "desktop") {
    return NextResponse.json(
      {
        error: "Unsupported screenshot scope",
        message: "Screenshot parsing accepts app/window or system-navigation screenshots, not full-desktop captures.",
      },
      { status: 400 },
    );
  }

  const model = screenshotParseModelForRequest(parsed.data);
  const credits = await requireInferenceCredits({
    model,
    provider: "gemini",
    route: inferenceUsageRoutes.screenshotParse,
    userId: request.donkey.userId,
  });
  if (!credits.ok) {
    return credits.response;
  }

  try {
    const result = await parseScreenshot(parsed.data);
    const recordedUsage = await recordInferenceUsage({
      clientId: client.clientId,
      metadata: {
        parserProvider: "gemini-flash",
      },
      model: result.model,
      provider: result.provider,
      requestKind: "screenshot_parse",
      route: inferenceUsageRoutes.screenshotParse,
      status: "succeeded",
      usage: result.usage,
      userId: request.donkey.userId,
    });

    return NextResponse.json(result.result, {
      headers: {
        "X-Donkey-Inference-Provider": result.provider,
        "X-Donkey-Inference-Model": result.model,
        ...creditUsageHeaders(recordedUsage),
      },
    });
  } catch (error) {
    if (error instanceof InferenceProviderError) {
      return NextResponse.json(
        {
          error: error.code,
          message: error.message,
          details: error.details,
        },
        { status: error.statusCode },
      );
    }

    throw error;
  }
});
