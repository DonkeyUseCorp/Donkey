import OpenAI, { APIError } from "openai";
import type { ResponseCreateParamsNonStreaming } from "openai/resources/responses/responses";

import {
  ensureConfigured,
  type FetchLike,
} from "@/lib/inference/http";
import { toJsonValue } from "@/lib/inference/json";
import { openaiModels } from "@/lib/inference/openai-models";
import {
  InferenceProviderError,
  type InferenceModality,
  type InferenceModel,
  type InferenceProvider,
  type JsonObject,
  type JsonValue,
  type ResponseCreateRequest,
  type ResponseCreateResult,
} from "@/lib/inference/providers";

type AdapterEnvironment = Record<string, string | undefined>;

const providerID = "hosted-responses";
const openAIProviderID = "openai";
const openAIBaseURL = "https://api.openai.com/v1";
const debugUIInspectionToolType = "donkey_debug_ui_inspection";
const defaultOpenAIDebugInspectionModel = openaiModels.debugInspection;
const unsupportedOpenAIComputerUseParameters = ["temperature", "top_p", "topP"];

export function createHostedResponsesProvider(
  environment: AdapterEnvironment = process.env,
  fetcher: FetchLike = fetch,
): InferenceProvider {
  const openAIKey = environment.OPENAI_API_KEY?.trim() ?? "";
  const configured = openAIKey.length > 0;

  async function listModels(modalities: InferenceModality[]) {
    const requested = modalities.length > 0 ? modalities : ["text"];
    if (!requested.includes("text") && !requested.includes("image")) {
      return [];
    }

    if (!openAIKey) {
      return [];
    }

    return [
      staticModel(defaultOpenAIDebugInspectionModel),
    ];
  }

  async function createResponse(
    request: ResponseCreateRequest,
  ): Promise<ResponseCreateResult> {
    ensureConfigured(configured);
    if (!isOpenAIResponsesToolRequest(request.body)) {
      throw new InferenceProviderError(
        "OpenAI Responses is only configured for read-only debug UI inspection.",
        {
          statusCode: 400,
          code: "openai_computer_tool_required",
          details: {
            supportedTools: [
              debugUIInspectionToolType,
            ],
          },
        },
      );
    }

    const client = new OpenAI({
      apiKey: openAIKey,
      baseURL: openAIBaseURL,
      fetch: fetcher,
    });

    try {
      const model = defaultOpenAIModel(request.body);
      const body = requestBody(request.body, model);
      const response = await client.responses.create(
        body as unknown as ResponseCreateParamsNonStreaming,
      );
      const value = toJsonValue(response);
      return {
        provider: openAIProviderID,
        model,
        body: value,
        usage: usageFromResponse(value),
        metadata: {
          provider: openAIProviderID,
          baseURL: openAIBaseURL,
          store: String(body.store ?? false),
        },
      };
    } catch (error) {
      throw providerError("OpenAI Responses computer-use request failed.", error);
    }
  }

  return {
    id: providerID,
    configured,
    capabilities: ["text", "image"],
    responseProviderIDs: [openAIProviderID],
    canCreateResponse: (request) => isOpenAIResponsesToolRequest(request.body),
    listModels,
    createResponse,
  };
}

function defaultOpenAIModel(_body: JsonObject) {
  return defaultOpenAIDebugInspectionModel;
}

function requestBody(body: JsonObject, model: string): JsonObject {
  const normalizedBody = normalizeOpenAIComputerUseBody(body);
  return {
    ...normalizedBody,
    model,
    stream: false,
    store: boolValue(normalizedBody.store, false),
  };
}

function normalizeOpenAIComputerUseBody(body: JsonObject): JsonObject {
  const hasDebugInspectionTool = hasDebugUIInspectionTool(body);
  if (!hasDebugInspectionTool) {
    return body;
  }

  const tools = body.tools;
  const toolChoice = openAIComputerToolChoice(body.tool_choice);
  const normalized: JsonObject = {
    ...body,
    instructions: openAIInstructions(body.instructions),
    ...(toolChoice === undefined ? {} : { tool_choice: toolChoice }),
  };
  for (const parameter of unsupportedOpenAIComputerUseParameters) {
    delete normalized[parameter];
  }
  if (Array.isArray(tools)) {
    const normalizedTools = tools
      .map(openAIComputerToolReference)
      .filter((tool): tool is JsonObject => isJsonObject(tool));
    if (normalizedTools.length > 0) {
      normalized.tools = normalizedTools;
    } else {
      delete normalized.tools;
    }
  }
  return normalized;
}

function openAIComputerToolChoice(value: JsonValue | undefined): JsonValue | undefined {
  if (!isJsonObject(value)) {
    return value;
  }

  const reference = openAIComputerToolReference(value);
  if (reference !== value) {
    return reference;
  }

  if (value.type !== "allowed_tools" || !Array.isArray(value.tools)) {
    return value;
  }

  return {
    ...value,
    tools: value.tools.map(openAIComputerToolReference),
  };
}

// The debug-inspection tool is read-only and has no OpenAI-native equivalent, so it is stripped from
// the request (the work is driven entirely by the inspection instructions). Any other tool passes
// through untouched.
function openAIComputerToolReference(value: JsonValue): JsonValue | null {
  if (!isJsonObject(value)) {
    return value;
  }

  if (value.type === debugUIInspectionToolType) {
    return null;
  }

  return value;
}

function openAIInstructions(value: JsonValue | undefined) {
  return [
    stringValue(value),
    [
      "Perform read-only macOS UI inspection from the provided screenshot.",
      "Return strict JSON only and do not return computer_call, function_call, click, type, scroll, drag, or navigation actions.",
    ].join(" "),
  ].filter(Boolean).join("\n\n");
}

function staticModel(model: string): InferenceModel {
  return {
    id: model,
    name: model,
    provider: openAIProviderID,
    inputModalities: ["text", "image"],
    outputModalities: ["text"],
    contextLength: null,
    pricing: null,
    metadata: {
      provider: openAIProviderID,
      baseURL: openAIBaseURL,
      api: "responses",
      registeredTools: [
        debugUIInspectionToolType,
      ],
    },
  };
}

function isOpenAIResponsesToolRequest(body: JsonObject) {
  const tools = body.tools;
  if (!Array.isArray(tools)) {
    return false;
  }

  return tools.some((tool) => {
    return isJsonObject(tool) && tool.type === debugUIInspectionToolType;
  });
}

function hasDebugUIInspectionTool(body: JsonObject) {
  const tools = body.tools;
  if (!Array.isArray(tools)) {
    return false;
  }

  return tools.some((tool) => {
    return isJsonObject(tool) && tool.type === debugUIInspectionToolType;
  });
}

function usageFromResponse(value: JsonValue): JsonValue | undefined {
  if (!isJsonObject(value)) {
    return undefined;
  }
  return value.usage;
}

function boolValue(value: JsonValue | undefined, fallback: boolean) {
  return typeof value === "boolean" ? value : fallback;
}

function stringValue(value: JsonValue | undefined): string | undefined {
  return typeof value === "string" && value.trim() ? value : undefined;
}

function isJsonObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function providerError(message: string, error: unknown) {
  if (error instanceof APIError) {
    return new InferenceProviderError(message, {
      statusCode: error.status ?? 502,
      code: error.code ?? "provider_error",
      details: {
        body: toJsonValue(error.error ?? {}),
        requestID: error.requestID ?? null,
        status: error.status ?? null,
        type: error.type ?? null,
      },
    });
  }

  return new InferenceProviderError(message, {
    details: {
      message: error instanceof Error ? error.message : "Unknown error",
    },
  });
}
