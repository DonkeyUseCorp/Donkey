import { randomUUID } from "crypto";

import { isSafeRemoteAssetURL } from "@/lib/inference/http";
import type {
  AssetGenerationKind,
  AssetGenerationProviderResult,
  AssetGenerationRequest,
  GenerationOutputRef,
  JsonValue,
  StoredGenerationForProvider,
} from "@/lib/inference/providers";

type GenerationIdentity = {
  id: string;
  kind: AssetGenerationKind;
};

export function generationIDForRequest(request: AssetGenerationRequest) {
  return request.generationId?.trim() || randomUUID();
}

export function assetGenerationResponse(input: {
  generation: GenerationIdentity;
  result: AssetGenerationProviderResult;
}) {
  return {
    id: input.generation.id,
    kind: input.generation.kind,
    status: input.result.status,
    provider: input.result.provider,
    model: input.result.model,
    providerJobId: input.result.providerJobId ?? null,
    providerGenerationId: input.result.providerGenerationId ?? null,
    providerPollingUrl: input.result.providerPollingUrl ?? null,
    outputs: input.result.outputs.map(outputResponse),
    usage: input.result.usage ?? null,
    error: input.result.error ?? null,
    metadata: input.result.metadata ?? {},
  };
}

export function refreshedAssetGenerationResponse(input: {
  generation: StoredGenerationForProvider;
  result: AssetGenerationProviderResult;
}) {
  return assetGenerationResponse({
    generation: {
      id: input.generation.id,
      kind: input.generation.kind,
    },
    result: input.result,
  });
}

export function failedAssetGenerationResponse(input: {
  generation: GenerationIdentity;
  provider: string;
  model: string;
  error: JsonValue;
}) {
  return {
    id: input.generation.id,
    kind: input.generation.kind,
    status: "failed",
    provider: input.provider,
    model: input.model,
    providerJobId: null,
    providerGenerationId: null,
    providerPollingUrl: null,
    outputs: [],
    usage: null,
    error: input.error,
    metadata: {
      provider: input.provider,
    },
  };
}

function outputResponse(output: GenerationOutputRef): GenerationOutputRef {
  const response: GenerationOutputRef = {
    id: output.id,
    kind: output.kind,
  };

  const isDownloadableURL =
    output.url?.startsWith("data:") ||
    (output.url ? isSafeRemoteAssetURL(output.url) : false);
  if (output.url && isDownloadableURL) {
    response.url = output.url;
  }
  if (output.dataBase64) {
    response.dataBase64 = output.dataBase64;
  }
  if (output.contentType) {
    response.contentType = output.contentType;
  }
  if (output.filename) {
    response.filename = output.filename;
  }
  if (output.byteCount !== undefined) {
    response.byteCount = output.byteCount;
  }
  if (output.metadata) {
    response.metadata = output.metadata;
  }

  return response;
}
