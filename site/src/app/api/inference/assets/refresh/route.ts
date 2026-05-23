import { NextResponse } from "next/server";

import {
  failedAssetGenerationResponse,
  refreshedAssetGenerationResponse,
} from "@/lib/inference/assets";
import { toJsonValue } from "@/lib/inference/json";
import { InferenceProviderError } from "@/lib/inference/providers";
import { createProviderRegistry } from "@/lib/inference/router";
import {
  requireInferenceClientId,
  validationErrorResponse,
} from "@/lib/inference/responses";
import { storedGenerationForProviderSchema } from "@/lib/inference/schemas";
import { withDonkeyAuth } from "@/lib/donkey-api-auth";

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

  const registry = createProviderRegistry();
  try {
    const result = await registry.refresh(parsed.data);
    return NextResponse.json(
      refreshedAssetGenerationResponse({
        generation: parsed.data,
        result,
      }),
    );
  } catch (error) {
    if (error instanceof InferenceProviderError) {
      return NextResponse.json(
        failedAssetGenerationResponse({
          generation: {
            id: parsed.data.id,
            kind: parsed.data.kind,
          },
          provider: parsed.data.provider,
          model: parsed.data.model,
          error: toJsonValue({
            code: error.code,
            message: error.message,
            details: error.details,
          }),
        }),
        { status: error.statusCode },
      );
    }

    throw error;
  }
});
