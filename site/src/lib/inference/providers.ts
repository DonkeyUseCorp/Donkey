import type {
  assetGenerationRequestSchema,
  chatCompletionRequestSchema,
  responseCreateRequestSchema,
} from "@/lib/inference/schemas";
import type { z } from "zod";

export type InferenceModality = "text" | "image" | "video" | "audio" | "music";
export type AssetGenerationKind = "image" | "video" | "music";
export type GenerationStatus =
  | "pending"
  | "in_progress"
  | "completed"
  | "failed"
  | "cancelled";

export type JsonPrimitive = string | number | boolean | null;
export type JsonValue =
  | JsonPrimitive
  | JsonValue[]
  | { [key: string]: JsonValue };
export type JsonObject = { [key: string]: JsonValue };

export type ChatCompletionRequest = z.infer<typeof chatCompletionRequestSchema>;
export type ResponseCreateRequest = z.infer<typeof responseCreateRequestSchema>;
export type AssetGenerationRequest = z.infer<typeof assetGenerationRequestSchema>;

export type InferenceModel = {
  id: string;
  name: string;
  provider: string;
  inputModalities: InferenceModality[];
  outputModalities: InferenceModality[];
  contextLength: number | null;
  pricing: JsonValue | null;
  metadata: JsonObject;
};

export type GenerationOutputRef = {
  id: string;
  kind: InferenceModality;
  url?: string;
  dataBase64?: string;
  contentType?: string;
  filename?: string;
  byteCount?: number;
  metadata?: JsonObject;
};

export type TextCompletionResult = {
  provider: string;
  model: string;
  body: JsonValue;
  usage?: JsonValue;
  metadata?: JsonObject;
};

export type TextStreamResult = {
  provider: string;
  model: string;
  response: Response;
};

export type ResponseCreateResult = {
  provider: string;
  model: string;
  body: JsonValue;
  usage?: JsonValue;
  metadata?: JsonObject;
};

export type AssetGenerationProviderRequest = {
  generationId: string;
  request: AssetGenerationRequest;
};

export type AssetGenerationProviderResult = {
  provider: string;
  model: string;
  status: GenerationStatus;
  providerJobId?: string;
  providerGenerationId?: string;
  providerPollingUrl?: string;
  outputs: GenerationOutputRef[];
  usage?: JsonValue;
  error?: JsonValue;
  metadata?: JsonObject;
};

export type StoredGenerationForProvider = {
  id: string;
  kind: AssetGenerationKind;
  provider: string;
  model: string;
  providerJobId: string | null;
  providerGenerationId: string | null;
  providerPollingUrl: string | null;
  outputs: GenerationOutputRef[];
  metadata: JsonObject;
};

export type InferenceProvider = {
  id: string;
  configured: boolean;
  capabilities: InferenceModality[];
  responseProviderIDs?: string[];
  listModels: (modalities: InferenceModality[]) => Promise<InferenceModel[]>;
  completeText?: (
    request: ChatCompletionRequest,
  ) => Promise<TextCompletionResult>;
  streamCompletion?: (request: ChatCompletionRequest) => Promise<TextStreamResult>;
  createResponse?: (
    request: ResponseCreateRequest,
  ) => Promise<ResponseCreateResult>;
  canCreateResponse?: (request: ResponseCreateRequest) => boolean;
  // Positively declares that this provider handles audio/video input parts in a Responses request.
  // The router requires it for media requests so media is routed by capability, not by elimination
  // (a provider that omits this is never handed a media request that it would silently drop).
  handlesResponseMedia?: (request: ResponseCreateRequest) => boolean;
  generateAsset?: (
    request: AssetGenerationProviderRequest,
  ) => Promise<AssetGenerationProviderResult>;
  refreshAsset?: (
    generation: StoredGenerationForProvider,
  ) => Promise<AssetGenerationProviderResult>;
};

export class InferenceProviderError extends Error {
  public statusCode: number;
  public code: string;
  public details: JsonValue | null;

  public constructor(
    message: string,
    options: {
      statusCode?: number;
      code?: string;
      details?: JsonValue | null;
    } = {},
  ) {
    super(message);
    this.name = "InferenceProviderError";
    this.statusCode = options.statusCode ?? 502;
    this.code = options.code ?? "provider_error";
    this.details = options.details ?? null;
  }
}
