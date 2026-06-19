import { Modality } from "@google/genai";
import type { GenerateContentParameters } from "@google/genai";

import {
  defaultGeminiClientFactory,
  geminiApiError,
  geminiCandidateParts,
  geminiCandidates,
  geminiClientConfig,
  stringValue,
  type AdapterEnvironment,
  type GeminiClientFactory,
} from "@/lib/inference/adapters/gemini-client";
import { providerCreditPricing } from "@/lib/credits/provider-pricing";
import { geminiModelRoles } from "@/lib/inference/gemini-models";
import { ensureConfigured } from "@/lib/inference/http";
import { isJsonObject, toJsonObject, toJsonValue } from "@/lib/inference/json";
import {
  InferenceProviderError,
  type AssetGenerationProviderRequest,
  type AssetGenerationProviderResult,
  type GenerationOutputRef,
  type InferenceModality,
  type InferenceModel,
  type InferenceProvider,
  type JsonObject,
  type JsonValue,
  type StoredGenerationForProvider,
} from "@/lib/inference/providers";

// Generative image editing/generation provider. The harness reaches it through the
// provider-neutral `image.*` tools and the asset framework with provider unset, so the
// registry auto-selects this provider for kind="image". Gemini ("nano banana") is named
// only here; adding another model is a new model id or a sibling adapter, not an app change.
const providerID = "gemini";

export function createGeminiImageAssetProvider(
  environment: AdapterEnvironment = process.env,
  clientFactory: GeminiClientFactory = defaultGeminiClientFactory,
): InferenceProvider {
  const clientConfig = geminiClientConfig(environment);
  const configured = clientConfig.configured;
  const defaultModel =
    environment.GEMINI_IMAGE_MODEL?.trim() || geminiModelRoles.imageGeneration;

  async function listModels(
    modalities: InferenceModality[],
  ): Promise<InferenceModel[]> {
    if (!modalities.includes("image")) {
      return [];
    }
    return [
      {
        id: defaultModel,
        name: defaultModel,
        provider: providerID,
        inputModalities: ["text", "image"],
        outputModalities: ["image"],
        contextLength: null,
        pricing: null,
        metadata: { provider: providerID, api: "generateContent" },
      },
    ];
  }

  async function generateAsset({
    generationId,
    request,
  }: AssetGenerationProviderRequest): Promise<AssetGenerationProviderResult> {
    ensureConfigured(configured);

    if (request.kind !== "image") {
      throw new InferenceProviderError("Provider does not support this asset kind.", {
        statusCode: 400,
        code: "unsupported_asset_kind",
      });
    }

    const model = request.model?.trim() || defaultModel;
    // Fail before spending: the GEMINI_IMAGE_MODEL override (or a caller model) may resolve to an
    // id with no configured price. The preflight catches a caller-supplied model, but not a model
    // resolved from the env default, so guard here too — never run a generation we can't price.
    if (!providerCreditPricing(providerID, model)) {
      throw new InferenceProviderError(
        "No credit price is configured for the selected image model.",
        { statusCode: 500, code: "image_model_not_priced", details: { model } },
      );
    }
    const parts: JsonObject[] = [];
    const prompt = request.prompt?.trim();
    if (prompt) {
      parts.push({ text: prompt });
    }
    for (const image of inputImages(toJsonObject(request.inputs ?? {}))) {
      parts.push({ inlineData: { mimeType: image.mimeType, data: image.data } });
    }
    if (parts.length === 0) {
      throw new InferenceProviderError(
        "Image generation requires a prompt or an input image.",
        { statusCode: 400, code: "empty_image_request" },
      );
    }

    const params: GenerateContentParameters = {
      model,
      contents: [{ role: "user", parts }] as unknown as GenerateContentParameters["contents"],
      config: { responseModalities: [Modality.IMAGE, Modality.TEXT] },
    };
    const client = clientFactory(clientConfig.options);

    let rawResponse: unknown;
    try {
      rawResponse = await client.models.generateContent(params);
    } catch (error) {
      throw geminiApiError("Gemini image generation failed.", error);
    }

    const outputs = imageOutputs(toJsonValue(rawResponse), generationId);
    if (outputs.length === 0) {
      throw new InferenceProviderError("Gemini returned no image for this request.", {
        statusCode: 502,
        code: "empty_image_generation",
        details: { model },
      });
    }

    return {
      provider: providerID,
      model,
      status: "completed",
      outputs,
      usage: { generationCount: outputs.length },
      metadata: { provider: providerID, api: "generateContent" },
    };
  }

  async function refreshAsset(
    generation: StoredGenerationForProvider,
  ): Promise<AssetGenerationProviderResult> {
    // Gemini image generation is synchronous — there is nothing to poll. Echo the stored
    // outputs as completed so the refresh route stays valid for any caller that polls.
    return {
      provider: providerID,
      model: generation.model,
      status: "completed",
      outputs: generation.outputs,
      metadata: { provider: providerID, api: "generateContent" },
    };
  }

  return {
    id: providerID,
    configured,
    capabilities: ["image"],
    listModels,
    generateAsset,
    refreshAsset,
  };
}

type InlineImage = { data: string; mimeType: string };

// The image tools send inputs.images = [{ data, mimeType }]. Parse exactly that shape.
function inputImages(inputs: JsonObject | undefined): InlineImage[] {
  const list = inputs?.images;
  if (!Array.isArray(list)) {
    return [];
  }
  const images: InlineImage[] = [];
  for (const item of list) {
    if (!isJsonObject(item)) {
      continue;
    }
    const data = stringValue(item.data);
    if (!data) {
      continue;
    }
    images.push({ data, mimeType: stringValue(item.mimeType) ?? "image/png" });
  }
  return images;
}

function imageOutputs(raw: JsonValue, generationId: string): GenerationOutputRef[] {
  const outputs: GenerationOutputRef[] = [];
  let index = 0;
  for (const candidate of geminiCandidates(raw)) {
    for (const part of geminiCandidateParts(candidate)) {
      const inline = part.inlineData ?? part.inline_data;
      if (!isJsonObject(inline)) {
        continue;
      }
      const data = stringValue(inline.data);
      if (!data) {
        continue;
      }
      const mimeType =
        stringValue(inline.mimeType) ?? stringValue(inline.mime_type) ?? "image/png";
      outputs.push({
        id: `${generationId}-image-${index}`,
        kind: "image",
        dataBase64: data,
        contentType: mimeType,
        filename: `${generationId}-${index}.${extensionForMime(mimeType)}`,
        metadata: { source: "provider-output" },
      });
      index += 1;
    }
  }
  return outputs;
}

function extensionForMime(mimeType: string): string {
  switch (mimeType.toLowerCase()) {
    case "image/jpeg":
    case "image/jpg":
      return "jpg";
    case "image/webp":
      return "webp";
    case "image/heic":
      return "heic";
    case "image/gif":
      return "gif";
    default:
      return "png";
  }
}
