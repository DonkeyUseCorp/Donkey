import {
  ApiError,
  Environment,
  GoogleGenAI,
  ThinkingLevel,
} from "@google/genai";
import type {
  Content,
  GenerateContentConfig,
  GenerateContentParameters,
  Tool,
} from "@google/genai";

import {
  geminiClientConfig,
  type AdapterEnvironment,
  type GeminiClientFactory,
} from "@/lib/inference/adapters/gemini-client";
import { geminiModelRoles } from "@/lib/inference/gemini-models";
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

const providerID = "gemini-computer-use";
const geminiProviderID = "gemini";
const defaultDecisionResponsesModel = geminiModelRoles.fastDecision;
const defaultVertexResponsesModel = geminiModelRoles.chat;
const defaultComputerUseModel = geminiModelRoles.browserComputerUse;

export const geminiBrowserInteractionToolType = "donkey_gemini_browser_interaction";
export const debugUIInspectionToolType = "donkey_debug_ui_inspection";

// Note: `generic_harness_planning` is deliberately NOT fast-decision. Planning is the most
// reasoning-heavy step (routing, plan steps, applying loaded skill guidance, and the act-vs-confirm
// call), and the flash-lite model follows that nuanced guidance poorly — it tends to ask for
// clarification on requests a skill can resolve directly. Route planning to the stronger model.
const fastDecisionSchemaNames = new Set([
  "task_intent_v1",
  "task_followup_resolution_v1",
]);

const fastDecisionPromptVersions = new Set([
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

// Maps a caller's `thinking_level` string to the SDK enum. Accepts the documented lowercase values
// (and tolerates casing); returns undefined for anything unrecognized so the caller can fall back to
// the legacy thinking_budget path.
function thinkingLevelFromBody(body: JsonObject): ThinkingLevel | undefined {
  const raw = stringValue(body.thinking_level) ?? stringValue(body.thinkingLevel);
  switch (raw?.trim().toLowerCase()) {
    case "minimal":
      return ThinkingLevel.MINIMAL;
    case "low":
      return ThinkingLevel.LOW;
    case "medium":
      return ThinkingLevel.MEDIUM;
    case "high":
      return ThinkingLevel.HIGH;
    default:
      return undefined;
  }
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
  // Bound reasoning so thinking tokens (which count against maxOutputTokens) can't starve the
  // structured output. Callers driving tight per-turn loops pass a small budget; 0 disables thinking.
  // Gemini 3.x models (e.g. gemini-3.5-flash) take thinking_level (minimal|low|medium|high), NOT the
  // integer thinking_budget — passing the budget to them is silently ignored. Prefer the level when the
  // caller sets it; the two are mutually exclusive. Older 2.x models still use thinking_budget. In both
  // cases request the thought summary so callers can persist the reasoning (the normalized response
  // separates it from output_text).
  const thinkingLevel = thinkingLevelFromBody(body);
  const thinkingBudget = numberValue(body.thinking_budget) ?? numberValue(body.thinkingBudget);
  if (thinkingLevel !== undefined) {
    config.thinkingConfig = { thinkingLevel, includeThoughts: true };
  } else if (thinkingBudget !== undefined) {
    config.thinkingConfig =
      thinkingBudget > 0 ? { thinkingBudget, includeThoughts: true } : { thinkingBudget };
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

    // `properties` and `$defs` are maps of caller-defined NAMES to sub-schemas — their keys are not
    // schema keywords and must be preserved. Sanitize each sub-schema value, keep every name.
    if ((key === "properties" || key === "$defs") && isJsonObject(child)) {
      const inner: JsonObject = {};
      for (const [name, subSchema] of Object.entries(child)) {
        const sanitizedSub = sanitizeGeminiJsonSchema(subSchema);
        if (sanitizedSub !== undefined) {
          inner[name] = sanitizedSub;
        }
      }
      sanitized[key] = inner;
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
  // Never degrade a JSON request to free-form: unconstrained Gemini output is frequently invalid
  // JSON (e.g. mangled keys), which is worse than a clean failure the caller can retry. For JSON
  // requests we keep asking for structured output and surface the error instead.
  if (request.config?.responseMimeType === "application/json") {
    return false;
  }
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
  const partObjects = parts.filter(isJsonObject);
  // Thought summaries (parts flagged `thought: true` when includeThoughts is on) must NOT land in
  // output_text — that field carries the structured JSON the caller parses. Keep them separate so the
  // reasoning can be persisted to the thread without corrupting the tool-call payload.
  const reasoningParts = partObjects
    .filter((part) => part.thought === true)
    .map((part) => stringValue(part.text))
    .filter((part): part is string => Boolean(part));
  const textParts = partObjects
    .filter((part) => part.thought !== true)
    .map((part) => stringValue(part.text))
    .filter((part): part is string => Boolean(part));
  const calls = partObjects
    .map(functionCallFromPart)
    .filter((part): part is JsonObject => Boolean(part));

  return {
    id: stringValue(isJsonObject(raw) ? raw.responseId : undefined) ?? `gemini-${Date.now()}`,
    object: "response",
    output_text: textParts.join("\n").trim(),
    reasoning_text: reasoningParts.join("\n").trim(),
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
