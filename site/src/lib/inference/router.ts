import { createAudioAssetProvider } from "@/lib/inference/adapters/audio-studio";
import { createPrimaryInferenceProvider } from "@/lib/inference/adapters/primary-router";
import {
  InferenceProviderError,
  type AssetGenerationRequest,
  type InferenceModality,
  type InferenceModel,
  type InferenceProvider,
  type StoredGenerationForProvider,
} from "@/lib/inference/providers";

export class ProviderRegistry {
  private providers: InferenceProvider[];

  public constructor(providers: InferenceProvider[]) {
    this.providers = providers;
  }

  public async listModels(modalities: InferenceModality[]) {
    const configuredProviders = this.providers.filter((provider) => provider.configured);
    if (configuredProviders.length === 0) {
      throw new InferenceProviderError("No configured inference provider is available.", {
        statusCode: 503,
        code: "no_inference_provider",
      });
    }

    const results: InferenceModel[] = [];
    for (const provider of configuredProviders) {
      results.push(...(await provider.listModels(modalities)));
    }

    return dedupeModels(results);
  }

  public textProvider(stream: boolean) {
    const provider = this.providers.find((candidate) => {
      return candidate.configured && (stream ? candidate.streamCompletion : candidate.completeText);
    });

    if (!provider) {
      throw new InferenceProviderError("No configured text inference provider is available.", {
        statusCode: 503,
        code: "no_text_provider",
      });
    }

    return provider;
  }

  public assetProvider(request: AssetGenerationRequest) {
    if (request.provider) {
      const provider = this.providers.find((candidate) => candidate.id === request.provider);
      if (!provider || !provider.generateAsset) {
        throw new InferenceProviderError("Requested inference provider is unavailable.", {
          statusCode: 404,
          code: "provider_not_found",
        });
      }

      if (!provider.configured) {
        throw new InferenceProviderError("Requested inference provider is not configured.", {
          statusCode: 503,
          code: "missing_provider_credentials",
        });
      }

      return provider;
    }

    const preferredCapabilities =
      request.kind === "music" ? ["music", "audio"] : [request.kind];

    const provider = this.providers.find((candidate) => {
      return (
        candidate.configured &&
        Boolean(candidate.generateAsset) &&
        preferredCapabilities.some((capability) => {
          return candidate.capabilities.includes(capability as InferenceModality);
        })
      );
    });

    if (!provider) {
      throw new InferenceProviderError("No configured asset generation provider is available.", {
        statusCode: 503,
        code: "no_asset_provider",
      });
    }

    return provider;
  }

  public providerForGeneration(generation: StoredGenerationForProvider) {
    const provider = this.providers.find((candidate) => candidate.id === generation.provider);
    if (!provider) {
      throw new InferenceProviderError("Generation provider is unavailable.", {
        statusCode: 404,
        code: "provider_not_found",
      });
    }

    if (!provider.configured) {
      throw new InferenceProviderError("Generation provider is not configured.", {
        statusCode: 503,
        code: "missing_provider_credentials",
      });
    }

    return provider;
  }

  public async refresh(generation: StoredGenerationForProvider) {
    const provider = this.providerForGeneration(generation);
    if (!provider.refreshAsset) {
      throw new InferenceProviderError("Generation provider cannot refresh assets.", {
        statusCode: 400,
        code: "refresh_not_supported",
      });
    }

    return provider.refreshAsset(generation);
  }
}

export function createProviderRegistry() {
  return new ProviderRegistry([
    createAudioAssetProvider(),
    createPrimaryInferenceProvider(),
  ]);
}

function dedupeModels(models: InferenceModel[]) {
  const seen = new Set<string>();
  const result: InferenceModel[] = [];
  for (const model of models) {
    const key = `${model.provider}:${model.id}`;
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    result.push(model);
  }

  return result;
}
