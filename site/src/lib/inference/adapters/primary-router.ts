import {
  HTTPClient as OpenRouterHTTPClient,
  OpenRouter,
} from "@openrouter/sdk";
import type {
  ChatRequest as OpenRouterChatRequest,
  ChatStreamChunk,
  Model as OpenRouterModel,
  Modality as OpenRouterModality,
  ProviderPreferences,
  VideoGenerationRequest as OpenRouterVideoGenerationRequest,
  VideoGenerationResponse,
} from "@openrouter/sdk/models";
import { OpenRouterError } from "@openrouter/sdk/models/errors";

import {
  ensureConfigured,
  type FetchLike,
} from "@/lib/inference/http";
import { toJsonObject, toJsonValue } from "@/lib/inference/json";
import { extractMediaOutputs } from "@/lib/inference/media-outputs";
import {
  InferenceProviderError,
  type AssetGenerationProviderRequest,
  type AssetGenerationProviderResult,
  type ChatCompletionRequest,
  type GenerationOutputRef,
  type GenerationStatus,
  type InferenceModality,
  type InferenceModel,
  type InferenceProvider,
  type JsonValue,
  type StoredGenerationForProvider,
  type TextCompletionResult,
  type TextStreamResult,
} from "@/lib/inference/providers";

type AdapterEnvironment = Record<string, string | undefined>;
type NonStreamingChatRequest = OpenRouterChatRequest & { stream?: false };
type StreamingChatRequest = OpenRouterChatRequest & { stream: true };

const providerID = "openrouter";

export function createPrimaryInferenceProvider(
  environment: AdapterEnvironment = process.env,
  fetcher: FetchLike = fetch,
): InferenceProvider {
  const apiKey = environment.OPENROUTER_API_KEY?.trim() ?? "";
  const configured = apiKey.length > 0;
  const client = new OpenRouter({
    apiKey,
    appTitle: environment.DONKEY_INFERENCE_TITLE?.trim() || undefined,
    httpClient: new OpenRouterHTTPClient({ fetcher }),
    httpReferer: environment.DONKEY_INFERENCE_HTTP_REFERER?.trim() || undefined,
  });

  async function listModels(modalities: InferenceModality[]) {
    try {
      const requested = modalities.filter((item) => item !== "music");
      const outputModalities = requested.length > 0 ? requested.join(",") : "text";
      const response = await client.models.list({ outputModalities });
      return response.data.map(normalizeModel);
    } catch (error) {
      throw providerError("Unable to list inference models.", error);
    }
  }

  async function completeText(
    request: ChatCompletionRequest,
  ): Promise<TextCompletionResult> {
    ensureConfigured(configured);

    try {
      const result = await client.chat.send({
        chatRequest: chatRequestFromCompletion(request, false),
      });

      return {
        provider: providerID,
        model: selectedModel(request),
        body: toJsonValue(result),
        usage: result.usage ? toJsonValue(result.usage) : undefined,
        metadata: { provider: providerID },
      };
    } catch (error) {
      throw providerError("Inference completion failed.", error);
    }
  }

  async function streamCompletion(
    request: ChatCompletionRequest,
  ): Promise<TextStreamResult> {
    ensureConfigured(configured);

    try {
      const stream = await client.chat.send({
        chatRequest: chatRequestFromCompletion(request, true),
      });

      return {
        provider: providerID,
        model: selectedModel(request),
        response: serverSentEventResponse(stream),
      };
    } catch (error) {
      throw providerError("Inference stream failed.", error);
    }
  }

  async function generateAsset(
    request: AssetGenerationProviderRequest,
  ): Promise<AssetGenerationProviderResult> {
    ensureConfigured(configured);

    if (request.request.kind === "video") {
      return createVideo(request);
    }

    return createChatAsset(request);
  }

  async function refreshAsset(
    generation: StoredGenerationForProvider,
  ): Promise<AssetGenerationProviderResult> {
    ensureConfigured(configured);

    if (generation.kind !== "video") {
      throw new InferenceProviderError("Only video generations can be refreshed.", {
        statusCode: 400,
        code: "refresh_not_supported",
      });
    }

    if (!generation.providerJobId) {
      throw new InferenceProviderError("Generation has no provider job id.", {
        statusCode: 400,
        code: "missing_provider_job_id",
      });
    }

    try {
      const result = await client.videoGeneration.getGeneration({
        jobId: generation.providerJobId,
      });
      return videoResult(generation.model, result);
    } catch (error) {
      throw providerError("Unable to refresh asset generation.", error);
    }
  }

  async function createChatAsset({
    request,
  }: AssetGenerationProviderRequest): Promise<AssetGenerationProviderResult> {
    try {
      const result = await client.chat.send({
        chatRequest: chatRequestFromAsset(request),
      });
      const outputs = extractMediaOutputs(toJsonValue(result), request.kind);

      return {
        provider: providerID,
        model: request.model,
        status: "completed",
        providerGenerationId: result.id,
        outputs,
        usage: result.usage ? toJsonValue(result.usage) : undefined,
        metadata: {
          provider: providerID,
          outputCount: String(outputs.length),
        },
      };
    } catch (error) {
      throw providerError("Asset generation failed.", error);
    }
  }

  async function createVideo({
    request,
  }: AssetGenerationProviderRequest): Promise<AssetGenerationProviderResult> {
    try {
      const result = await client.videoGeneration.generate({
        videoGenerationRequest: videoRequestFromAsset(request),
      });
      return videoResult(request.model, result);
    } catch (error) {
      throw providerError("Video generation failed.", error);
    }
  }

  return {
    id: providerID,
    configured,
    capabilities: ["text", "image", "video", "audio"],
    listModels,
    completeText,
    streamCompletion,
    generateAsset,
    refreshAsset,
  };
}

function selectedModel(request: ChatCompletionRequest) {
  const model = request.model ?? request.models?.[0];
  if (!model) {
    throw new InferenceProviderError("Inference request is missing a model.", {
      statusCode: 400,
      code: "missing_model",
    });
  }

  return model;
}

function normalizeModel(model: OpenRouterModel): InferenceModel {
  return {
    id: model.id,
    name: model.name,
    provider: providerID,
    inputModalities: readModalities(model.architecture.inputModalities),
    outputModalities: readModalities(model.architecture.outputModalities),
    contextLength: model.contextLength,
    pricing: toJsonValue(model.pricing),
    metadata: toJsonObject(model),
  };
}

function readModalities(values: string[]): InferenceModality[] {
  const supported = values.filter((item): item is InferenceModality => {
    return (
      item === "text" ||
      item === "image" ||
      item === "video" ||
      item === "audio" ||
      item === "music"
    );
  });

  return supported;
}

function chatRequestFromCompletion(
  request: ChatCompletionRequest,
  stream: false,
): NonStreamingChatRequest;
function chatRequestFromCompletion(
  request: ChatCompletionRequest,
  stream: true,
): StreamingChatRequest;
function chatRequestFromCompletion(
  request: ChatCompletionRequest,
  stream: boolean,
): NonStreamingChatRequest | StreamingChatRequest {
  const parameters = extraParameters(request, [
    "messages",
    "metadata",
    "modalities",
    "model",
    "models",
    "provider",
    "stream",
  ]);

  return compactObject({
    ...parameters,
    messages: request.messages,
    metadata: request.metadata,
    modalities: request.modalities
      ? openRouterModalities(request.modalities)
      : undefined,
    model: request.model,
    models: request.models,
    provider: request.provider as ProviderPreferences | undefined,
    stream,
  }) as NonStreamingChatRequest | StreamingChatRequest;
}

function chatRequestFromAsset(
  request: AssetGenerationProviderRequest["request"],
): NonStreamingChatRequest {
  return compactObject({
    ...toJsonObject(request.parameters ?? {}),
    messages: [{ role: "user", content: request.prompt }],
    metadata: request.metadata ?? {},
    modalities: openRouterModalities(
      request.kind === "image" ? ["image"] : ["audio", "text"],
    ),
    model: request.model,
    stream: false,
  }) as NonStreamingChatRequest;
}

function videoRequestFromAsset(
  request: AssetGenerationProviderRequest["request"],
): OpenRouterVideoGenerationRequest {
  return compactObject({
    ...toJsonObject(request.parameters ?? {}),
    model: request.model,
    prompt: request.prompt,
  }) as OpenRouterVideoGenerationRequest;
}

function openRouterModalities(values: string[]): OpenRouterModality[] {
  return values.filter((item): item is OpenRouterModality => {
    return item === "text" || item === "image" || item === "audio";
  });
}

function videoResult(
  model: string,
  result: VideoGenerationResponse,
): AssetGenerationProviderResult {
  const outputs = (result.unsignedUrls ?? []).map<GenerationOutputRef>(
    (url, index) => ({
      id: `video-${index + 1}`,
      kind: "video",
      url,
      contentType: "video/mp4",
      filename: `video-${index + 1}.mp4`,
      metadata: { source: "provider-output" },
    }),
  );

  return {
    provider: providerID,
    model,
    status: mapStatus(result.status),
    providerJobId: result.id,
    providerGenerationId: result.generationId,
    providerPollingUrl: result.pollingUrl,
    outputs,
    usage: result.usage ? toJsonValue(result.usage) : undefined,
    error: result.error ? { message: result.error } : undefined,
    metadata: {
      provider: providerID,
      outputCount: String(outputs.length),
    },
  };
}

function serverSentEventResponse(stream: AsyncIterable<ChatStreamChunk>) {
  const encoder = new TextEncoder();
  const body = new ReadableStream<Uint8Array>({
    async start(controller) {
      try {
        for await (const chunk of stream) {
          controller.enqueue(encoder.encode(`data: ${JSON.stringify(chunk)}\n\n`));
        }
        controller.enqueue(encoder.encode("data: [DONE]\n\n"));
        controller.close();
      } catch (error) {
        controller.error(error);
      }
    },
  });

  return new Response(body, {
    headers: {
      "Cache-Control": "no-cache",
      "Content-Type": "text/event-stream",
    },
  });
}

function mapStatus(value: string | null): GenerationStatus {
  switch (value) {
    case "completed":
      return "completed";
    case "in_progress":
    case "running":
      return "in_progress";
    case "failed":
    case "expired":
      return "failed";
    case "cancelled":
      return "cancelled";
    default:
      throw new InferenceProviderError("Provider returned an unknown generation status.", {
        statusCode: 502,
        code: "unknown_generation_status",
        details: { status: value },
      });
  }
}

function providerError(message: string, error: unknown) {
  if (error instanceof OpenRouterError) {
    return new InferenceProviderError(message, {
      statusCode: error.statusCode,
      details: {
        body: parseProviderBody(error.body),
        status: error.statusCode,
      },
    });
  }

  return new InferenceProviderError(message, {
    details: {
      message: error instanceof Error ? error.message : "Unknown error",
    },
  });
}

function parseProviderBody(value: string): JsonValue {
  if (!value) {
    return {};
  }

  try {
    return toJsonValue(JSON.parse(value));
  } catch {
    return { raw: value.slice(0, 4_000) };
  }
}

function compactObject(value: Record<string, unknown>) {
  return Object.fromEntries(
    Object.entries(value).filter(([, item]) => item !== undefined),
  );
}

function extraParameters(value: unknown, omittedKeys: string[]) {
  const parameters = toJsonObject(value);
  for (const key of omittedKeys) {
    delete parameters[key];
  }

  return parameters;
}
