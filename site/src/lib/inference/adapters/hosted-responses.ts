import OpenAI, { APIError } from "openai";
import type { ResponseCreateParamsNonStreaming } from "openai/resources/responses/responses";

import {
  ensureConfigured,
  type FetchLike,
} from "@/lib/inference/http";
import { toJsonValue } from "@/lib/inference/json";
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
const openAIMacDesktopInteractionToolType = "donkey_openai_mac_desktop_interaction";
const defaultOpenAIComputerUseModel = "gpt-5.5";

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

    return [staticModel(defaultOpenAIComputerUseModel)];
  }

  async function createResponse(
    request: ResponseCreateRequest,
  ): Promise<ResponseCreateResult> {
    ensureConfigured(configured);
    if (!isOpenAIComputerToolRequest(request.body)) {
      throw new InferenceProviderError(
        "OpenAI Responses is only configured for Mac desktop computer use.",
        {
          statusCode: 400,
          code: "openai_computer_tool_required",
          details: {
            supportedTools: [
              "computer",
              "computer_use_preview",
              openAIMacDesktopInteractionToolType,
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
      const body = requestBody(request.body, defaultOpenAIComputerUseModel);
      const response = await client.responses.create(
        body as unknown as ResponseCreateParamsNonStreaming,
      );
      const value = toJsonValue(response);
      return {
        provider: openAIProviderID,
        model: defaultOpenAIComputerUseModel,
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
    canCreateResponse: (request) => isOpenAIComputerToolRequest(request.body),
    listModels,
    createResponse,
  };
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
  if (!hasOpenAIMacDesktopTool(body)) {
    return body;
  }

  const tools = body.tools;
  const toolChoice = openAIComputerToolChoice(body.tool_choice);
  return {
    ...body,
    instructions: openAIMacDesktopInstructions(body.instructions),
    ...(toolChoice === undefined ? {} : { tool_choice: toolChoice }),
    ...(Array.isArray(tools)
      ? {
          tools: tools.map(openAIComputerToolReference),
        }
      : {}),
  };
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

function openAIComputerToolReference(value: JsonValue): JsonValue {
  if (!isJsonObject(value)) {
    return value;
  }

  if (value.type === openAIMacDesktopInteractionToolType) {
    return { type: "computer" };
  }

  if (
    (value.type === "function" || value.type === "custom") &&
    value.name === openAIMacDesktopInteractionToolType
  ) {
    return { type: "computer" };
  }

  return value;
}

function openAIMacDesktopInstructions(value: JsonValue | undefined) {
  return [
    stringValue(value),
    [
      "Use the OpenAI computer tool for non-browser Mac desktop UI work.",
      "The Mac client executes returned computer_call actions with focus, safety, permission, and screenshot feedback.",
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
      computerUse: true,
      registeredTools: [openAIMacDesktopInteractionToolType],
    },
  };
}

function isOpenAIComputerToolRequest(body: JsonObject) {
  const tools = body.tools;
  if (!Array.isArray(tools)) {
    return false;
  }

  return tools.some((tool) => {
    return (
      isJsonObject(tool) &&
      (tool.type === "computer" ||
        tool.type === "computer_use_preview" ||
        tool.type === openAIMacDesktopInteractionToolType)
    );
  });
}

function hasOpenAIMacDesktopTool(body: JsonObject) {
  const tools = body.tools;
  if (!Array.isArray(tools)) {
    return false;
  }

  return tools.some((tool) => {
    return isJsonObject(tool) && tool.type === openAIMacDesktopInteractionToolType;
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
