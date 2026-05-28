import {
  ApiError,
  Environment,
  GoogleGenAI,
} from "@google/genai";
import { JWT, type JWTInput } from "google-auth-library";
import type {
  Content,
  GenerateContentConfig,
  GenerateContentParameters,
  GoogleGenAIOptions,
  Tool,
} from "@google/genai";

import { ensureConfigured } from "@/lib/inference/http";
import {
  isJsonObject,
  toJsonObject,
  toJsonValue,
} from "@/lib/inference/json";
import {
  InferenceProviderError,
  type ChatCompletionRequest,
  type InferenceModality,
  type InferenceModel,
  type InferenceProvider,
  type JsonObject,
  type JsonValue,
  type ResponseCreateRequest,
  type ResponseCreateResult,
  type TextCompletionResult,
} from "@/lib/inference/providers";

type AdapterEnvironment = Record<string, string | undefined>;
type GeminiClient = Pick<GoogleGenAI, "models">;
type GeminiClientFactory = (options: GoogleGenAIOptions) => GeminiClient;

const providerID = "gemini-computer-use";
const geminiProviderID = "gemini";
const defaultDecisionResponsesModel = "gemini-3.1-flash-lite";
const defaultVertexResponsesModel = "gemini-3.5-flash";
const defaultComputerUseModel = "gemini-3-flash-preview";
const vertexLocation = "global";
const vertexAIScope = "https://www.googleapis.com/auth/cloud-platform";

export const geminiBrowserInteractionToolType = "donkey_gemini_browser_interaction";
export const debugUIInspectionToolType = "donkey_debug_ui_inspection";

const fastDecisionSchemaNames = new Set([
  "generic_harness_planning",
  "task_intent_v1",
  "task_followup_resolution_v1",
]);

const fastDecisionPromptVersions = new Set([
  "task-intent-v1",
  "task-followup-resolution-v1",
]);

const browserOnlyFunctionExclusions = [
  "drag_and_drop",
];

export function createGeminiComputerUseProvider(
  environment: AdapterEnvironment = process.env,
  clientFactory: GeminiClientFactory = (options) => new GoogleGenAI(options),
): InferenceProvider {
  const clientConfig = geminiClientConfig(environment);
  const configured = clientConfig.configured;

  async function listModels(modalities: InferenceModality[]) {
    const requested = modalities.length > 0 ? modalities : ["text"];
    if (!requested.includes("text") && !requested.includes("image")) {
      return [];
    }

    return [
      staticModel(defaultDecisionResponsesModel, false),
      staticModel(defaultVertexResponsesModel, false),
      staticModel(defaultComputerUseModel, true),
    ];
  }

  async function createResponse(
    request: ResponseCreateRequest,
  ): Promise<ResponseCreateResult> {
    ensureConfigured(configured);

    const registeredTools = registeredToolTypes(request.body.tools);
    if (hasExplicitUnsupportedTools(request.body.tools)) {
      throw new InferenceProviderError("Gemini Responses received unsupported tool declarations.", {
        statusCode: 400,
        code: "gemini_tool_unsupported",
        details: {
          supportedTools: [
            geminiBrowserInteractionToolType,
            debugUIInspectionToolType,
          ],
        },
      });
    }

    const model = requestedModel(
      request.body,
      defaultResponseModel(request.body, registeredTools),
    );
    const requestParameters = geminiGenerateContentParameters(
      request.body,
      registeredTools,
      model,
    );
    const client = clientFactory(clientConfig.options);

    let rawResponse: unknown;
    let retriedWithoutSchema = false;
    try {
      rawResponse = await client.models.generateContent(requestParameters);
    } catch (error) {
      if (shouldRetryWithoutStructuredSchema(error, requestParameters)) {
        retriedWithoutSchema = true;
        try {
          rawResponse = await client.models.generateContent(
            withoutStructuredResponseSchema(requestParameters),
          );
        } catch (retryError) {
          throw geminiProviderError(retryError);
        }
      } else {
        throw geminiProviderError(error);
      }
    }

    const rawBody = toJsonValue(rawResponse);
    const body = normalizedGeminiResponse(toJsonValue(rawBody), registeredTools);
    return {
      provider: geminiProviderID,
      model,
      body,
      usage: isJsonObject(body) ? body.usage : undefined,
      metadata: {
        provider: geminiProviderID,
        api: "google-genai-sdk",
        service: clientConfig.service,
        registeredTools,
        structuredSchemaRetry: String(retriedWithoutSchema),
      },
    };
  }

  async function completeText(
    request: ChatCompletionRequest,
  ): Promise<TextCompletionResult> {
    ensureConfigured(configured);

    const model = requestedChatModel(
      request,
      defaultVertexResponsesModel,
    );
    const body = toJsonObject(request);
    const requestParameters: GenerateContentParameters = {
      model,
      contents: contentsFromInput(toJsonValue(request.messages)),
      config: generationConfigFromBody(body),
    };
    const client = clientFactory(clientConfig.options);

    let rawResponse: unknown;
    try {
      rawResponse = await client.models.generateContent(requestParameters);
    } catch (error) {
      throw geminiProviderError(error);
    }

    const rawBody = toJsonValue(rawResponse);
    const normalized = normalizedGeminiResponse(rawBody, []);
    const outputText = stringValue(normalized.output_text) ?? "";
    return {
      provider: geminiProviderID,
      model,
      body: chatCompletionBody(rawBody, model, outputText),
      usage: isJsonObject(rawBody) ? rawBody.usageMetadata ?? null : undefined,
      metadata: {
        provider: geminiProviderID,
        api: "google-genai-sdk",
        service: clientConfig.service,
      },
    };
  }

  return {
    id: providerID,
    configured,
    capabilities: ["text", "image"],
    responseProviderIDs: [geminiProviderID],
    canCreateResponse: (request) => {
      return !hasExplicitUnsupportedTools(request.body.tools);
    },
    listModels,
    completeText,
    createResponse,
  };
}

function geminiGenerateContentParameters(
  body: JsonObject,
  registeredTools: string[],
  model: string,
): GenerateContentParameters {
  const tools = geminiTools(registeredTools, body.tools);
  const generationConfig = generationConfigFromBody(body);
  const systemInstruction = systemInstructionFromBody(body);
  const config: GenerateContentConfig = {
    ...generationConfig,
  };
  if (tools.length > 0) {
    config.tools = tools;
  }
  if (systemInstruction) {
    config.systemInstruction = systemInstruction;
  }

  return {
    model,
    contents: contentsFromInput(body.input),
    config,
  };
}

function geminiTools(registeredTools: string[], rawTools: JsonValue | undefined): Tool[] {
  const tools: Tool[] = [];
  const hasBrowser = registeredTools.includes(geminiBrowserInteractionToolType);

  if (hasBrowser) {
    tools.push({
      computerUse: {
        environment: Environment.ENVIRONMENT_BROWSER,
        excludedPredefinedFunctions: excludedPredefinedFunctions(
          rawTools,
          browserOnlyFunctionExclusions,
        ),
      },
    });
  }

  return tools;
}

function contentsFromInput(input: JsonValue | undefined): Content[] {
  if (typeof input === "string") {
    return [
      {
        role: "user",
        parts: [{ text: input }],
      },
    ];
  }

  if (!Array.isArray(input)) {
    return [];
  }

  return input.map((item) => {
    if (!isJsonObject(item)) {
      return {
        role: "user",
        parts: [partFromValue(item)],
      };
    }

    return {
      role: geminiRole(stringValue(item.role)),
      parts: partsFromContent(item.content ?? item.parts ?? item),
    };
  }) as Content[];
}

function partsFromContent(content: JsonValue): JsonObject[] {
  if (Array.isArray(content)) {
    return content.map(partFromValue);
  }

  return [partFromValue(content)];
}

function partFromValue(value: JsonValue): JsonObject {
  if (typeof value === "string") {
    return { text: value };
  }

  if (!isJsonObject(value)) {
    return { text: JSON.stringify(value) };
  }

  if (isJsonObject(value.functionResponse)) {
    return { functionResponse: value.functionResponse };
  }

  if (isJsonObject(value.function_response)) {
    return { functionResponse: value.function_response };
  }

  if (isJsonObject(value.functionCall)) {
    return { functionCall: value.functionCall };
  }

  if (isJsonObject(value.function_call)) {
    return { functionCall: value.function_call };
  }

  if (value.type === "function_response") {
    return functionResponsePart(value);
  }

  if (value.type === "input_image" || value.type === "image") {
    return imagePart(value);
  }

  const text = stringValue(value.text);
  if (text) {
    return { text };
  }

  return { text: JSON.stringify(value) };
}

function imagePart(value: JsonObject): JsonObject {
  const mimeType = stringValue(value.mime_type) || stringValue(value.mimeType) || "image/png";
  const base64 = stringValue(value.image_base64) || stringValue(value.dataBase64);
  if (base64) {
    return {
      inlineData: {
        mimeType,
        data: base64,
      },
    };
  }

  const imageURL = stringValue(value.image_url) || stringValue(value.url);
  if (imageURL?.startsWith("data:")) {
    const inline = dataURLToInlineData(imageURL);
    if (inline) {
      return inline;
    }
  }

  if (imageURL) {
    return {
      fileData: {
        mimeType,
        fileUri: imageURL,
      },
    };
  }

  return { text: JSON.stringify(value) };
}

function functionResponsePart(value: JsonObject): JsonObject {
  const name = stringValue(value.name) || "unknown_function";
  const response = isJsonObject(value.response) ? value.response : {};
  const screenshotBase64 =
    stringValue(value.screenshotBase64) ||
    (isJsonObject(value.screenshot) ? stringValue(value.screenshot.base64) : undefined);
  const mimeType =
    stringValue(value.mimeType) ||
    stringValue(value.mime_type) ||
    (isJsonObject(value.screenshot) ? stringValue(value.screenshot.mimeType) : undefined) ||
    "image/png";

  const functionResponse: JsonObject = {
    name,
    response,
  };
  if (screenshotBase64) {
    functionResponse.parts = [
      {
        inlineData: {
          mimeType,
          data: screenshotBase64,
        },
      },
    ];
  }

  return { functionResponse };
}

function dataURLToInlineData(value: string): JsonObject | null {
  const match = /^data:([^;,]+);base64,(.+)$/u.exec(value);
  if (!match) {
    return null;
  }

  return {
    inlineData: {
      mimeType: match[1],
      data: match[2],
    },
  };
}

function generationConfigFromBody(body: JsonObject): Partial<GenerateContentConfig> {
  const config: Partial<GenerateContentConfig> = {};
  const temperature = numberValue(body.temperature);
  if (temperature !== undefined) {
    config.temperature = temperature;
  }

  const topP = numberValue(body.top_p) ?? numberValue(body.topP);
  if (topP !== undefined) {
    config.topP = topP;
  }

  const maxOutputTokens = numberValue(body.max_output_tokens) ?? numberValue(body.maxOutputTokens);
  if (maxOutputTokens !== undefined) {
    config.maxOutputTokens = maxOutputTokens;
  }
  const responseFormat = responseFormatFromBody(body);
  if (responseFormat?.json) {
    config.responseMimeType = "application/json";
    if (responseFormat.schema) {
      config.responseJsonSchema = geminiJsonSchema(responseFormat.schema);
    }
  }

  return config;
}

const supportedGeminiJsonSchemaKeys = new Set([
  "$anchor",
  "$defs",
  "$id",
  "$ref",
  "additionalProperties",
  "anyOf",
  "description",
  "enum",
  "format",
  "items",
  "maxItems",
  "maximum",
  "minItems",
  "minimum",
  "oneOf",
  "prefixItems",
  "properties",
  "propertyOrdering",
  "required",
  "title",
  "type",
]);

function geminiJsonSchema(schema: JsonObject): JsonObject {
  const sanitized = sanitizeGeminiJsonSchema(schema);
  return sanitized !== undefined && isJsonObject(sanitized) ? sanitized : schema;
}

function sanitizeGeminiJsonSchema(value: JsonValue): JsonValue | undefined {
  if (Array.isArray(value)) {
    return value
      .map(sanitizeGeminiJsonSchema)
      .filter((item): item is JsonValue => item !== undefined);
  }

  if (!isJsonObject(value)) {
    return value;
  }

  const sanitized: JsonObject = {};
  for (const [key, child] of Object.entries(value)) {
    if (!supportedGeminiJsonSchemaKeys.has(key)) {
      continue;
    }

    const childValue = sanitizeGeminiJsonSchema(child);
    if (childValue !== undefined) {
      sanitized[key] = childValue;
    }
  }

  if (
    sanitized.type === "object" &&
    isJsonObject(sanitized.properties) &&
    !Array.isArray(sanitized.propertyOrdering)
  ) {
    sanitized.propertyOrdering = Object.keys(sanitized.properties);
  }

  return sanitized;
}

function shouldRetryWithoutStructuredSchema(
  error: unknown,
  request: GenerateContentParameters,
) {
  return (
    hasStructuredResponseSchema(request) &&
    error instanceof ApiError &&
    error.status === 400
  );
}

function hasStructuredResponseSchema(request: GenerateContentParameters) {
  const config = request.config;
  return Boolean(
    config &&
      ("responseJsonSchema" in config || "responseSchema" in config),
  );
}

function withoutStructuredResponseSchema(
  request: GenerateContentParameters,
): GenerateContentParameters {
  const restConfig = { ...(request.config ?? {}) };
  delete restConfig.responseJsonSchema;
  delete restConfig.responseSchema;

  return {
    ...request,
    config: restConfig,
  };
}

function responseFormatFromBody(body: JsonObject): { json: boolean; schema?: JsonObject } | null {
  const format =
    isJsonObject(body.text) && isJsonObject(body.text.format)
      ? body.text.format
      : isJsonObject(body.response_format)
        ? body.response_format
        : null;
  if (!format) {
    return null;
  }

  const type = stringValue(format.type);
  if (type === "json_schema") {
    return {
      json: true,
      schema: isJsonObject(format.schema) ? format.schema : undefined,
    };
  }
  if (type === "json_object") {
    return { json: true };
  }

  return null;
}

function defaultResponseModel(body: JsonObject, registeredTools: string[]) {
  if (registeredTools.includes(geminiBrowserInteractionToolType)) {
    return defaultComputerUseModel;
  }

  if (registeredTools.includes(debugUIInspectionToolType)) {
    return defaultDecisionResponsesModel;
  }

  if (isFastDecisionRequest(body)) {
    return defaultDecisionResponsesModel;
  }

  return defaultVertexResponsesModel;
}

function isFastDecisionRequest(body: JsonObject) {
  const metadata = isJsonObject(body.metadata) ? body.metadata : {};
  const promptVersion =
    stringValue(metadata.prompt_version) ??
    stringValue(metadata.promptVersion);
  if (promptVersion && fastDecisionPromptVersions.has(promptVersion)) {
    return true;
  }

  const format =
    isJsonObject(body.text) && isJsonObject(body.text.format)
      ? body.text.format
      : isJsonObject(body.response_format)
        ? body.response_format
        : null;
  const schemaName = format ? stringValue(format.name) : undefined;
  return Boolean(schemaName && fastDecisionSchemaNames.has(schemaName));
}

function systemInstructionFromBody(body: JsonObject): string | undefined {
  const instruction = [
    stringValue(body.instructions),
  ].filter(Boolean).join("\n\n");

  if (!instruction) {
    return undefined;
  }

  return instruction;
}

function normalizedGeminiResponse(
  raw: JsonValue,
  registeredTools: string[],
): JsonObject {
  const candidates = isJsonObject(raw) && Array.isArray(raw.candidates)
    ? raw.candidates
    : [];
  const firstCandidate = candidates.find(isJsonObject);
  const parts =
    firstCandidate &&
    isJsonObject(firstCandidate.content) &&
    Array.isArray(firstCandidate.content.parts)
      ? firstCandidate.content.parts
      : [];
  const textParts = parts
    .filter(isJsonObject)
    .map((part) => stringValue(part.text))
    .filter((part): part is string => Boolean(part));
  const calls = parts
    .filter(isJsonObject)
    .map(functionCallFromPart)
    .filter((part): part is JsonObject => Boolean(part));

  return {
    id: stringValue(isJsonObject(raw) ? raw.responseId : undefined) ?? `gemini-${Date.now()}`,
    object: "response",
    output_text: textParts.join("\n").trim(),
    output: [
      {
        type: "message",
        role: "assistant",
        content: textParts.map((text) => ({
          type: "output_text",
          text,
        })),
      },
      ...calls.map((call) => ({
        type: "function_call",
        ...call,
      })),
    ],
    computer_use: {
      registered_tools: registeredTools,
      calls,
    },
    provider_output: raw,
    usage: isJsonObject(raw) ? raw.usageMetadata ?? null : null,
  };
}

function functionCallFromPart(part: JsonObject): JsonObject | null {
  const value = isJsonObject(part.functionCall)
    ? part.functionCall
    : isJsonObject(part.function_call)
      ? part.function_call
      : null;
  if (!value) {
    return null;
  }

  return {
    id: stringValue(value.id) ?? `call-${Math.random().toString(36).slice(2)}`,
    name: stringValue(value.name) ?? "unknown_function",
    arguments: isJsonObject(value.args) ? value.args : {},
  };
}

function registeredToolTypes(tools: JsonValue | undefined): string[] {
  if (!Array.isArray(tools)) {
    return [];
  }

  const registered = new Set<string>();
  for (const tool of tools) {
    if (!isJsonObject(tool)) {
      continue;
    }
    if (tool.type === geminiBrowserInteractionToolType) {
      registered.add(geminiBrowserInteractionToolType);
    } else if (tool.type === debugUIInspectionToolType) {
      registered.add(debugUIInspectionToolType);
    }
  }
  return [...registered];
}

function excludedPredefinedFunctions(rawTools: JsonValue | undefined, defaults: string[]) {
  const excluded = new Set(defaults);
  if (Array.isArray(rawTools)) {
    for (const tool of rawTools) {
      if (!isJsonObject(tool)) {
        continue;
      }
      const values = Array.isArray(tool.excludedPredefinedFunctions)
        ? tool.excludedPredefinedFunctions
        : Array.isArray(tool.excluded_predefined_functions)
          ? tool.excluded_predefined_functions
          : [];
      for (const value of values) {
        if (typeof value === "string" && value.trim()) {
          excluded.add(value.trim());
        }
      }
    }
  }
  return [...excluded];
}

function geminiRole(value: string | undefined) {
  return value === "assistant" || value === "model" ? "model" : "user";
}

function requestedModel(body: JsonObject, fallback: string) {
  const model = body.model;
  return typeof model === "string" && model.trim() ? model : fallback;
}

function requestedChatModel(request: ChatCompletionRequest, fallback: string) {
  return request.model?.trim() || request.models?.[0]?.trim() || fallback;
}

function geminiClientConfig(environment: AdapterEnvironment): {
  configured: boolean;
  options: GoogleGenAIOptions;
  service: "vertex-ai";
} {
  const apiVersion = environment.GEMINI_API_VERSION?.trim() || undefined;
  const timeout = numberFromString(environment.GEMINI_TIMEOUT_MS);
  const httpOptions: GoogleGenAIOptions["httpOptions"] | undefined =
    timeout === undefined ? undefined : { timeout };
  const googleCredentials = googleCredentialsFromEnvironment(environment);
  const project = googleCredentials?.project_id;

  const options: GoogleGenAIOptions = {
    vertexai: true,
    location: vertexLocation,
  };
  if (project) {
    options.project = project;
  }
  if (apiVersion) {
    options.apiVersion = apiVersion;
  }
  if (httpOptions) {
    options.httpOptions = httpOptions;
  }
  if (googleCredentials) {
    options.googleAuthOptions = {
      authClient: googleAuthClient(googleCredentials),
    };
  }

  return {
    configured: Boolean(project),
    options,
    service: "vertex-ai",
  };
}

function googleCredentialsFromEnvironment(
  environment: AdapterEnvironment,
): JWTInput | undefined {
  const rawCredentials = environment.GOOGLE_APPLICATION_CREDENTIALS_JSON?.trim();
  if (!rawCredentials) {
    return undefined;
  }

  return serviceAccountCredentials(rawCredentials);
}

function googleAuthClient(credentials: JWTInput) {
  return new JWT({
    email: credentials.client_email,
    key: credentials.private_key,
    keyId: credentials.private_key_id,
    scopes: [vertexAIScope],
  });
}

function serviceAccountCredentials(rawCredentials: string): JWTInput {
  let parsed: unknown;
  try {
    parsed = JSON.parse(rawCredentials);
  } catch {
    throw new InferenceProviderError("Google service account JSON is invalid.", {
      statusCode: 500,
      code: "invalid_google_service_account_json",
    });
  }

  const credentials = toJsonValue(parsed);
  if (!isJsonObject(credentials)) {
    throw new InferenceProviderError("Google service account JSON must be an object.", {
      statusCode: 500,
      code: "invalid_google_service_account_json",
    });
  }

  const clientEmail = stringValue(credentials.client_email);
  const privateKey = stringValue(credentials.private_key);
  if (!clientEmail || !privateKey) {
    throw new InferenceProviderError(
      "Google service account JSON must include client_email and private_key.",
      {
        statusCode: 500,
        code: "invalid_google_service_account_json",
      },
    );
  }

  return {
    type: stringValue(credentials.type),
    project_id: stringValue(credentials.project_id),
    private_key_id: stringValue(credentials.private_key_id),
    private_key: privateKey,
    client_email: clientEmail,
    client_id: stringValue(credentials.client_id),
    universe_domain: stringValue(credentials.universe_domain),
  };
}

function geminiProviderError(error: unknown) {
  if (error instanceof ApiError) {
    return new InferenceProviderError("Gemini request failed.", {
      statusCode: error.status,
      code: "provider_error",
      details: {
        status: error.status,
        message: error.message,
      },
    });
  }

  return new InferenceProviderError("Gemini request failed.", {
    details: {
      message: error instanceof Error ? error.message : "Unknown error",
    },
  });
}

function chatCompletionBody(
  raw: JsonValue,
  model: string,
  outputText: string,
): JsonObject {
  return {
    id: stringValue(isJsonObject(raw) ? raw.responseId : undefined) ?? `gemini-${Date.now()}`,
    object: "chat.completion",
    model,
    choices: [
      {
        index: 0,
        message: {
          role: "assistant",
          content: outputText,
        },
        finish_reason: "stop",
      },
    ],
    usage: isJsonObject(raw) ? raw.usageMetadata ?? null : null,
    provider_output: raw,
  };
}

function hasExplicitUnsupportedTools(
  tools: JsonValue | undefined,
) {
  if (!Array.isArray(tools)) {
    return false;
  }

  return tools.some((tool) => {
    if (!isJsonObject(tool)) {
      return true;
    }
    return tool.type !== geminiBrowserInteractionToolType &&
      tool.type !== debugUIInspectionToolType;
  });
}

function staticModel(model: string, computerUse: boolean): InferenceModel {
  return {
    id: model,
    name: model,
    provider: geminiProviderID,
    inputModalities: ["text", "image"],
    outputModalities: ["text"],
    contextLength: 1_048_576,
    pricing: null,
    metadata: {
      provider: geminiProviderID,
      api: "generateContent",
      ...(computerUse
        ? {
            computerUse,
            registeredTools: [
              geminiBrowserInteractionToolType,
              debugUIInspectionToolType,
            ],
          }
        : { structuredOutputs: true }),
    },
  };
}

function stringValue(value: JsonValue | undefined): string | undefined {
  return typeof value === "string" && value.trim() ? value : undefined;
}

function numberValue(value: JsonValue | undefined): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function numberFromString(value: string | undefined): number | undefined {
  if (!value?.trim()) {
    return undefined;
  }
  const number = Number(value);
  return Number.isFinite(number) ? number : undefined;
}
