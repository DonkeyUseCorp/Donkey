import { NextResponse } from "next/server";

import {
  creditUsageHeaders,
  inferenceUsageRoutes,
  recordInferenceUsage,
  requireInferenceCredits,
} from "@/lib/credits/inference";
import { createProviderRegistry } from "@/lib/inference/router";
import {
  requireInferenceClientId,
  validationErrorResponse,
} from "@/lib/inference/responses";
import { responseCreateRequestSchema } from "@/lib/inference/schemas";
import { withDonkeyAuth } from "@/lib/donkey-api-auth";

export const dynamic = "force-dynamic";

export const POST = withDonkeyAuth(async (request) => {
  const client = requireInferenceClientId(request.donkey.clientId);
  if (!client.ok) {
    return client.response;
  }

  const parsed = responseCreateRequestSchema.safeParse(await request.json());
  if (!parsed.success) {
    return validationErrorResponse(parsed.error);
  }

  const requestedModel =
    typeof parsed.data.body.model === "string" && parsed.data.body.model.trim()
      ? parsed.data.body.model.trim()
      : "unknown";
  const credits = await requireInferenceCredits({
    model: requestedModel,
    provider: parsed.data.donkeyProvider,
    route: inferenceUsageRoutes.responses,
    userId: request.donkey.userId,
  });
  if (!credits.ok) {
    return credits.response;
  }

  const registry = createProviderRegistry();
  const provider = registry.responsesProvider(parsed.data);
  const result = await provider.createResponse?.(parsed.data);
  if (!result) {
    return NextResponse.json(
      {
        error: "Responses unavailable",
      },
      { status: 503 },
    );
  }

  const recordedUsage = await recordInferenceUsage({
    clientId: client.clientId,
    model: result.model,
    provider: result.provider,
    requestKind: "responses",
    route: inferenceUsageRoutes.responses,
    status: "succeeded",
    usage: result.usage,
    userId: request.donkey.userId,
  });

  return NextResponse.json(result.body, {
    headers: {
      "X-Donkey-Inference-Provider": result.provider,
      "X-Donkey-Inference-Model": result.model,
      ...creditUsageHeaders(recordedUsage),
    },
  });
});
