import { NextResponse } from "next/server";

import {
  inferenceUsageRoutes,
  recordFailedInferenceUsage,
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

    // A successful poll is free and already covered by the submit-time charge, so it writes no
    // usage event — only failed refreshes are recorded, as the diagnostic trail.
    return NextResponse.json(
      refreshedAssetGenerationResponse({
        generation: parsed.data,
        result,
      }),
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
