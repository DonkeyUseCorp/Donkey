import { NextResponse } from "next/server";

import {
  creditErrorResponse,
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

  // Select the provider before the preflight so credit limits and pricing are scoped to the real
  // provider (not a model-neutral request). This also lets the preflight reject an unpriced
  // caller-supplied model before the provider runs and bills upstream.
  let provider;
  try {
    provider = createProviderRegistry().assetProvider(parsed.data);
  } catch (error) {
    if (error instanceof InferenceProviderError) {
      return inferenceProviderErrorResponse(error);
    }
    throw error;
  }

  const credits = await requireInferenceCredits({
    model: parsed.data.model,
    provider: provider.id,
    route: inferenceUsageRoutes.assets,
    userId: request.donkey.userId,
    // Asset generation bills the requested model, so reject an unpriced one before the provider
    // runs and bills upstream — never produce a generation we can't charge for.
    enforceModelPrice: true,
  });
  if (!credits.ok) {
    return credits.response;
  }

  const failedUsageProvider = provider.id;

  try {
    const generationId = generationIDForRequest(parsed.data);
    const generation = {
      id: generationId,
      kind: parsed.data.kind,
    };
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
    const creditResponse = creditErrorResponse(error);
    if (creditResponse) {
      return creditResponse;
    }
    if (error instanceof InferenceProviderError) {
      return inferenceProviderErrorResponse(error);
    }

    throw error;
  }
});
