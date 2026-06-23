import { NextResponse } from "next/server";

import {
  creditUsageHeaders,
  inferenceUsageRoutes,
  recordFailedInferenceUsage,
  recordInferenceUsage,
  requireInferenceCredits,
} from "@/lib/credits/inference";
import { refreshedAssetGenerationResponse } from "@/lib/inference/assets";
import { createProviderRegistry } from "@/lib/inference/router";
import {
  inferenceErrorCode,
  inferenceProviderErrorResponse,
  requireInferenceClientId,
  validationErrorResponse,
} from "@/lib/inference/responses";
import { storedGenerationForProviderSchema } from "@/lib/inference/schemas";
import { withDonkeyAuth } from "@/lib/donkey-api-auth";
import { InferenceProviderError } from "@/lib/inference/providers";

export const dynamic = "force-dynamic";

export const POST = withDonkeyAuth(async (request) => {
  const client = requireInferenceClientId(request.donkey.clientId);
  if (!client.ok) {
    return client.response;
  }

  const parsed = storedGenerationForProviderSchema.safeParse(await request.json());
  if (!parsed.success) {
    return validationErrorResponse(parsed.error);
  }

  const credits = await requireInferenceCredits({
    model: parsed.data.model,
    provider: parsed.data.provider,
    route: inferenceUsageRoutes.assetsRefresh,
    userId: request.donkey.userId,
  });
  if (!credits.ok) {
    return credits.response;
  }

  try {
    const registry = createProviderRegistry();
    const result = await registry.refresh(parsed.data);
    const recordedUsage = await recordInferenceUsage({
      clientId: client.clientId,
      conversationId: request.donkey.conversationId,
      metadata: {
        assetKind: parsed.data.kind,
      },
      model: result.model,
      provider: result.provider,
      requestKind: "asset_refresh",
      route: inferenceUsageRoutes.assetsRefresh,
      status: "succeeded",
      usage: result.usage,
      userId: request.donkey.userId,
    });

    return NextResponse.json(
      refreshedAssetGenerationResponse({
        generation: parsed.data,
        result,
      }),
      {
        headers: creditUsageHeaders(recordedUsage),
      },
    );
  } catch (error) {
    await recordFailedInferenceUsage({
      clientId: client.clientId,
      conversationId: request.donkey.conversationId,
      errorCode: inferenceErrorCode(error),
      metadata: {
        assetKind: parsed.data.kind,
      },
      model: parsed.data.model,
      provider: parsed.data.provider,
      requestKind: "asset_refresh",
      route: inferenceUsageRoutes.assetsRefresh,
      userId: request.donkey.userId,
    });
    if (error instanceof InferenceProviderError) {
      return inferenceProviderErrorResponse(error);
    }

    throw error;
  }
});
