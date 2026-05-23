import { NextResponse } from "next/server";

import {
  assetGenerationResponse,
  failedAssetGenerationResponse,
  generationIDForRequest,
} from "@/lib/inference/assets";
import { createProviderRegistry } from "@/lib/inference/router";
import {
  requireInferenceClientId,
  validationErrorResponse,
} from "@/lib/inference/responses";
import { assetGenerationRequestSchema } from "@/lib/inference/schemas";
import { toJsonValue } from "@/lib/inference/json";
import { InferenceProviderError } from "@/lib/inference/providers";
import { withDonkeyAuth } from "@/lib/donkey-api-auth";

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

  const registry = createProviderRegistry();
  const provider = registry.assetProvider(parsed.data);
  const generationId = generationIDForRequest(parsed.data);
  const generation = {
    id: generationId,
    kind: parsed.data.kind,
  };

  try {
    const result = await provider.generateAsset?.({
      generationId,
      request: parsed.data,
    });

    if (!result) {
      throw new InferenceProviderError("Provider cannot generate assets.", {
        statusCode: 400,
        code: "asset_generation_unavailable",
      });
    }

    return NextResponse.json(assetGenerationResponse({ generation, result }), {
      status: 201,
    });
  } catch (error) {
    const failed = failedAssetGenerationResponse({
      generation,
      provider: provider.id,
      model: parsed.data.model,
      error: toJsonValue(
        error instanceof InferenceProviderError
          ? {
              code: error.code,
              message: error.message,
              details: error.details,
            }
          : {
              message: error instanceof Error ? error.message : "Unknown error",
            },
      ),
    });

    if (error instanceof InferenceProviderError) {
      return NextResponse.json(
        {
          ...failed,
          error: {
            code: error.code,
            message: error.message,
            details: error.details,
          },
        },
        { status: error.statusCode },
      );
    }

    throw error;
  }
});
