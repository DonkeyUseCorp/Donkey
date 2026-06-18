import { NextResponse } from "next/server";

import {
  creditUsageHeaders,
  inferenceUsageRoutes,
  recordFailedInferenceUsage,
  recordInferenceUsage,
  requireInferenceCredits,
} from "@/lib/credits/inference";
import {
  assetGenerationResponse,
  generationIDForRequest,
} from "@/lib/inference/assets";
import { createProviderRegistry } from "@/lib/inference/router";
import {
  inferenceErrorCode,
  inferenceProviderErrorResponse,
  requireInferenceClientId,
  validationErrorResponse,
} from "@/lib/inference/responses";
import { assetGenerationRequestSchema } from "@/lib/inference/schemas";
import { withDonkeyAuth } from "@/lib/donkey-api-auth";
import { InferenceProviderError } from "@/lib/inference/providers";

export const dynamic = "force-dynamic";

export const POST = withDonkeyAuth(async (request) => {
  const client = requireInferenceClientId(request.donkey.clientId);
  if (!client.ok) {
    return client.response;
  }

  const parsed = assetGenerationRequestSchema.safeParse(await request.json());
  if (!parsed.success) {
    return validationErrorResponse(parsed.error);
  }

  const credits = await requireInferenceCredits({
    model: parsed.data.model,
    provider: parsed.data.provider,
    route: inferenceUsageRoutes.assets,
    userId: request.donkey.userId,
  });
  if (!credits.ok) {
    return credits.response;
  }

  let failedUsageProvider = parsed.data.provider ?? "default";

  try {
    const generationId = generationIDForRequest(parsed.data);
    const generation = {
      id: generationId,
      kind: parsed.data.kind,
    };
    const registry = createProviderRegistry();
    const provider = registry.assetProvider(parsed.data);
    failedUsageProvider = provider.id;
    const result = await provider.generateAsset?.({
      generationId,
      request: parsed.data,
    });

    if (!result) {
      await recordFailedInferenceUsage({
        clientId: client.clientId,
        errorCode: "asset_generation_unavailable",
        metadata: {
          assetKind: parsed.data.kind,
        },
        model: parsed.data.model ?? "default",
        provider: failedUsageProvider,
        requestKind: "asset_generation",
        route: inferenceUsageRoutes.assets,
        userId: request.donkey.userId,
      });

      return NextResponse.json(
        {
          error: "Asset generation unavailable",
        },
        { status: 503 },
      );
    }

    const recordedUsage = await recordInferenceUsage({
      clientId: client.clientId,
      metadata: {
        assetKind: parsed.data.kind,
      },
      model: result.model,
      provider: result.provider,
      requestKind: "asset_generation",
      route: inferenceUsageRoutes.assets,
      status: "succeeded",
      usage: result.usage,
      userId: request.donkey.userId,
    });

    return NextResponse.json(assetGenerationResponse({ generation, result }), {
      headers: creditUsageHeaders(recordedUsage),
      status: 201,
    });
  } catch (error) {
    await recordFailedInferenceUsage({
      clientId: client.clientId,
      errorCode: inferenceErrorCode(error),
      metadata: {
        assetKind: parsed.data.kind,
      },
      model: parsed.data.model ?? "default",
      provider: failedUsageProvider,
      requestKind: "asset_generation",
      route: inferenceUsageRoutes.assets,
      userId: request.donkey.userId,
    });
    if (error instanceof InferenceProviderError) {
      return inferenceProviderErrorResponse(error);
    }

    throw error;
  }
});
