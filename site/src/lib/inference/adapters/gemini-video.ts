import { GenerateVideosOperation, GoogleGenAI } from "@google/genai";
import type {
  GenerateVideosConfig,
  GenerateVideosParameters,
  GoogleGenAIOptions,
} from "@google/genai";

import {
  geminiApiError,
  geminiClientConfig,
  stringValue,
  type AdapterEnvironment,
} from "@/lib/inference/adapters/gemini-client";
import { providerCreditPricing } from "@/lib/credits/provider-pricing";
import { veoModels, veoTierModels } from "@/lib/inference/gemini-models";
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

// Generative text/image-to-video provider (Veo). The harness reaches it through the
// provider-neutral `video.generate` tool and the asset framework with provider unset, so the
// registry auto-selects this provider for kind="video". Veo is a long-running operation, so unlike
// the synchronous image adapter this submits a job and the Mac side polls refresh until it lands.
// A DISTINCT provider id ("veo", not "gemini") keeps that refresh routing from colliding with the
// image adapter. Adopting a newer Veo is a one-line change in gemini-models.ts, not an app change.
const providerID = "veo";

// Veo needs both `models` (submit) and `operations` (poll) on the client; the shared GeminiClient
// type only exposes `models`, so this adapter constructs its own wider client. Injectable for tests.
export type GeminiVideoClient = Pick<GoogleGenAI, "models" | "operations">;
export type GeminiVideoClientFactory = (options: GoogleGenAIOptions) => GeminiVideoClient;

const defaultVideoClientFactory: GeminiVideoClientFactory = (options) =>
  new GoogleGenAI(options);

export function createGeminiVideoAssetProvider(
  environment: AdapterEnvironment = process.env,
  clientFactory: GeminiVideoClientFactory = defaultVideoClientFactory,
): InferenceProvider {
  const clientConfig = geminiClientConfig(environment);
  const configured = clientConfig.configured;

  // Model selection lives in code: the speed/quality tier the user picks maps to a hardcoded Veo id
  // (see gemini-models.ts), so video is on by default rather than gated behind an env var. Vertex AI
  // is assumed (see geminiClientConfig).
  async function listModels(
    modalities: InferenceModality[],
  ): Promise<InferenceModel[]> {
    if (!modalities.includes("video")) {
      return [];
    }
    return Object.values(veoModels).map((id) => ({
      id,
      name: id,
      provider: providerID,
      inputModalities: ["text", "image"],
      outputModalities: ["video"],
      contextLength: null,
      pricing: null,
      metadata: { provider: providerID, api: "generateVideos" },
    }));
  }

  function resolveModel(requested?: string, tier?: string): string {
    const tierModel =
      veoTierModels[tier?.trim().toLowerCase() as keyof typeof veoTierModels];
    const model = requested?.trim() || tierModel || veoModels.fast;
    // Fail before spending: the resolved model must have a configured price. A hardcoded Veo id
    // always resolves; this only bites if a caller passes an unpriced model override.
    if (!providerCreditPricing(providerID, model)) {
      throw new InferenceProviderError(
        "No credit price is configured for the selected video model.",
        { statusCode: 500, code: "video_model_not_priced", details: { model } },
      );
    }
    return model;
  }

  async function generateAsset({
    generationId,
    request,
  }: AssetGenerationProviderRequest): Promise<AssetGenerationProviderResult> {
    ensureConfigured(configured);

    if (request.kind !== "video") {
      throw new InferenceProviderError("Provider does not support this asset kind.", {
        statusCode: 400,
        code: "unsupported_asset_kind",
      });
    }

    const requestParameters = toJsonObject(request.parameters ?? {});
    const model = resolveModel(request.model, stringValue(requestParameters.tier));
    const prompt = request.prompt?.trim();
    const image = inputImage(toJsonObject(request.inputs ?? {}));
    if (!prompt && !image) {
      throw new InferenceProviderError(
        "Video generation requires a prompt or an input image.",
        { statusCode: 400, code: "empty_video_request" },
      );
    }

    const params: GenerateVideosParameters = {
      model,
      ...(prompt ? { prompt } : {}),
      ...(image
        ? { image: { imageBytes: image.data, mimeType: image.mimeType } }
        : {}),
      config: videoConfig(requestParameters),
    };

    const client = clientFactory(clientConfig.options);
    let operation: GenerateVideosOperation;
    try {
      operation = await client.models.generateVideos(params);
    } catch (error) {
      throw geminiApiError("Veo video generation failed.", error);
    }

    // Rare fast path: the job may already be complete on submit.
    const completed = completedOutputs(operation, generationId, model);
    if (completed) {
      return completed;
    }
    if (operation.done) {
      // Done on submit but produced no video — surface the provider's reason instead of "pending".
      throw new InferenceProviderError("Veo returned no video for this request.", {
        statusCode: 502,
        code: "empty_video_generation",
        details: { model, error: operationError(operation) ?? null },
      });
    }

    const operationName = operation.name?.trim();
    if (!operationName) {
      throw new InferenceProviderError("Veo did not return an operation to poll.", {
        statusCode: 502,
        code: "video_operation_missing",
        details: { model },
      });
    }

    // In progress: charge the flat clip price now (generationCount = 1). The assets/refresh route is
    // free, so submit time is the only billable point; hand the operation handle back for the Mac
    // side to poll via refreshAsset.
    return {
      provider: providerID,
      model,
      status: "in_progress",
      providerJobId: operationName,
      providerGenerationId: operationName,
      providerPollingUrl: operationName,
      outputs: [],
      usage: { generationCount: 1 },
      metadata: { provider: providerID, api: "generateVideos", operationName },
    };
  }

  async function refreshAsset(
    generation: StoredGenerationForProvider,
  ): Promise<AssetGenerationProviderResult> {
    ensureConfigured(configured);

    const operationName =
      generation.providerGenerationId?.trim() ||
      generation.providerJobId?.trim() ||
      stringValue(generation.metadata?.operationName);
    if (!operationName) {
      return failedResult(generation.model, {
        message: "No Veo operation handle to poll.",
      });
    }

    const client = clientFactory(clientConfig.options);
    // The SDK polls by calling methods on the operation instance itself, so a plain
    // `{ name }` literal is not enough — construct a real GenerateVideosOperation.
    const operationHandle = new GenerateVideosOperation();
    operationHandle.name = operationName;
    let operation: GenerateVideosOperation;
    try {
      operation = await client.operations.getVideosOperation({
        operation: operationHandle,
      });
    } catch (error) {
      throw geminiApiError("Polling the Veo operation failed.", error);
    }

    // No usage on completion — the flat clip price was charged at submit, and assets/refresh is free.
    const completed = completedOutputs(operation, generation.id, generation.model);
    if (completed) {
      return completed;
    }
    if (operation.done) {
      return failedResult(
        generation.model,
        operationError(operation) ?? { message: "Veo returned no video." },
      );
    }

    // Still running — echo in_progress (no billable usage) so the Mac side keeps polling.
    return {
      provider: providerID,
      model: generation.model,
      status: "in_progress",
      providerJobId: operationName,
      providerGenerationId: operationName,
      providerPollingUrl: operationName,
      outputs: [],
      metadata: { provider: providerID, api: "generateVideos", operationName },
    };
  }

  return {
    id: providerID,
    configured,
    capabilities: ["video"],
    listModels,
    generateAsset,
    refreshAsset,
  };
}

type InlineImage = { data: string; mimeType: string };

// The video tool sends an optional first-frame image as inputs.images = [{ data, mimeType }] for
// image-to-video; reuse exactly the shape the image tool sends. Only the first image is used.
function inputImage(inputs: JsonObject | undefined): InlineImage | undefined {
  const list = inputs?.images;
  if (!Array.isArray(list)) {
    return undefined;
  }
  for (const item of list) {
    if (!isJsonObject(item)) {
      continue;
    }
    const data = stringValue(item.data);
    if (!data) {
      continue;
    }
    return { data, mimeType: stringValue(item.mimeType) ?? "image/png" };
  }
  return undefined;
}

// Veo knobs the tool may pass through request.parameters; audio defaults on, one video per call.
function videoConfig(parameters: JsonObject | undefined): GenerateVideosConfig {
  const config: GenerateVideosConfig = { numberOfVideos: 1, generateAudio: true };
  if (!parameters) {
    return config;
  }
  const aspectRatio = stringValue(parameters.aspectRatio);
  if (aspectRatio) {
    config.aspectRatio = aspectRatio;
  }
  const resolution = stringValue(parameters.resolution);
  if (resolution) {
    config.resolution = resolution;
  }
  const negativePrompt = stringValue(parameters.negativePrompt);
  if (negativePrompt) {
    config.negativePrompt = negativePrompt;
  }
  const durationSeconds = numberValue(parameters.durationSeconds);
  if (durationSeconds !== undefined) {
    config.durationSeconds = durationSeconds;
  }
  const generateAudio = boolValue(parameters.generateAudio);
  if (generateAudio !== undefined) {
    config.generateAudio = generateAudio;
  }
  // Person-safety: unset, Veo blocks person/face generation (fatal for any shot
  // with a character). Callers pass DONT_ALLOW/ALLOW_ADULT/ALLOW_ALL — note Veo
  // caps image-to-video at ALLOW_ADULT (no minors); ALLOW_ALL needs text-to-video.
  const personGeneration = stringValue(parameters.personGeneration);
  if (personGeneration) {
    config.personGeneration = personGeneration as GenerateVideosConfig["personGeneration"];
  }
  return config;
}

// A completed result from a finished operation that produced video, or undefined when the operation
// is still running or finished without any video (the caller decides how to surface those).
function completedOutputs(
  operation: GenerateVideosOperation,
  generationId: string,
  model: string,
): AssetGenerationProviderResult | undefined {
  if (!operation.done) {
    return undefined;
  }
  const videos = operation.response?.generatedVideos ?? [];
  const outputs: GenerationOutputRef[] = [];
  let index = 0;
  for (const generated of videos) {
    const video = generated.video;
    if (!video) {
      continue;
    }
    const mimeType = video.mimeType ?? "video/mp4";
    const filename = `${generationId}-${index}.${extensionForVideoMime(mimeType)}`;
    // Prefer inline bytes (the reliable path on Vertex with no output bucket); fall back to a URI the
    // Mac side can fetch. A gs:// URI is not directly fetchable, so inline bytes are what we expect.
    if (video.videoBytes) {
      outputs.push({
        id: `${generationId}-video-${index}`,
        kind: "video",
        dataBase64: video.videoBytes,
        contentType: mimeType,
        filename,
        metadata: { source: "provider-output" },
      });
      index += 1;
    } else if (video.uri) {
      outputs.push({
        id: `${generationId}-video-${index}`,
        kind: "video",
        url: video.uri,
        contentType: mimeType,
        filename,
        metadata: { source: "provider-output" },
      });
      index += 1;
    }
  }
  if (outputs.length === 0) {
    return undefined;
  }
  return {
    provider: providerID,
    model,
    status: "completed",
    outputs,
    metadata: { provider: providerID, api: "generateVideos" },
  };
}

function failedResult(
  model: string,
  error: JsonValue,
): AssetGenerationProviderResult {
  return {
    provider: providerID,
    model,
    status: "failed",
    outputs: [],
    error,
    metadata: { provider: providerID, api: "generateVideos" },
  };
}

function operationError(operation: GenerateVideosOperation): JsonValue | undefined {
  return operation.error ? toJsonValue(operation.error) : undefined;
}

function numberValue(value: JsonValue | undefined): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function boolValue(value: JsonValue | undefined): boolean | undefined {
  return typeof value === "boolean" ? value : undefined;
}

function extensionForVideoMime(mimeType: string): string {
  switch (mimeType.toLowerCase()) {
    case "video/webm":
      return "webm";
    case "video/quicktime":
    case "video/mov":
      return "mov";
    default:
      return "mp4";
  }
}
