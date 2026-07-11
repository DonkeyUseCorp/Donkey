import {
  ApiError,
  GoogleGenAI,
  MediaResolution,
  Type,
} from "@google/genai";
import { JWT, type JWTInput } from "google-auth-library";
import type {
  GenerateContentParameters,
  GoogleGenAIOptions,
  Schema,
} from "@google/genai";

import { geminiModelRoles } from "@/lib/inference/gemini-models";
import { ensureConfigured } from "@/lib/inference/http";
import {
  isJsonObject,
  toJsonValue,
} from "@/lib/inference/json";
import {
  InferenceProviderError,
  type JsonValue,
} from "@/lib/inference/providers";
import { normalizedScreenshotResult } from "@/lib/inference/screenshot-parsing/normalize";
import {
  geminiScreenshotParseOutputSchema,
  geminiScreenshotControlSchema,
  type GeminiScreenshotParseOutput,
  type ScreenshotParseRequest,
} from "@/lib/inference/screenshot-parsing/schema";
import type { ScreenshotParserProvider } from "@/lib/inference/screenshot-parsing/types";

type AdapterEnvironment = Record<string, string | undefined>;
type GeminiClient = Pick<GoogleGenAI, "models">;
type GeminiClientFactory = (options: GoogleGenAIOptions) => GeminiClient;

const geminiProviderID = "gemini";
const screenshotProviderID = "gemini-flash";
const defaultScreenshotParseModel = geminiModelRoles.screenshotParse;
const defaultDebugOverlayScreenshotParseModel = geminiModelRoles.screenshotParse;
const defaultVertexLocation = "global";
const vertexAIScope = "https://www.googleapis.com/auth/cloud-platform";
// Client-side request timeout so a stalled parse aborts instead of hanging the
// per-step agent loop; screenshot parsing is normally a few seconds, so this only
// trips on a true hang.
const requestTimeoutMs = 120_000;

export function createGeminiFlashScreenshotParser(
  environment: AdapterEnvironment = process.env,
  clientFactory: GeminiClientFactory = (options) => new GoogleGenAI(options),
): ScreenshotParserProvider {
  const config = geminiClientConfig(environment);

  return {
    id: screenshotProviderID,
    inferenceProvider: geminiProviderID,
    configured: config.configured,
    modelForRequest: (request) => screenshotParseModelForRequest(request),
    async parse(request) {
      ensureConfigured(config.configured);
      const client = clientFactory(config.options);
      const model = screenshotParseModelForRequest(request);
      const startedAt = performance.now();

      let rawResponse: unknown;
      try {
        rawResponse = await client.models.generateContent(
          geminiRequestParameters(request, model),
        );
      } catch (error) {
        throw geminiProviderError(error);
      }

      const rawBody = toJsonValue(rawResponse);
      const output = parseGeminiOutput(rawBody);
      const result = normalizedScreenshotResult(request, output, {
        provider: geminiProviderID,
        parserProvider: screenshotProviderID,
        model,
        service: config.service,
        location: config.location,
        latencyMs: String(Math.round(performance.now() - startedAt)),
      });

      return {
        provider: geminiProviderID,
        model,
        result,
        usage: usageFromGeminiResponse(rawBody),
        metadata: result.metadata,
      };
    },
    async *stream(request) {
      ensureConfigured(config.configured);
      const client = clientFactory(config.options);
      const model = screenshotParseModelForRequest(request);
      const startedAt = performance.now();
      const generator = await streamGeminiContent(client, request, model);
      let accumulatedText = "";
      let emittedControlCount = 0;
      let latestUsage: JsonValue | undefined;

      for await (const chunk of generator) {
        accumulatedText += geminiResponseText(chunk);
        latestUsage = usageFromGeminiResponse(toJsonValue(chunk)) ?? latestUsage;

        const partialOutput = partialGeminiOutput(accumulatedText);
        if (partialOutput.controls.length <= emittedControlCount) {
          continue;
        }

        emittedControlCount = partialOutput.controls.length;
        const result = normalizedScreenshotResult(request, partialOutput, {
          provider: geminiProviderID,
          parserProvider: screenshotProviderID,
          model,
          service: config.service,
          location: config.location,
          latencyMs: String(Math.round(performance.now() - startedAt)),
          "screenshotParser.stream": "partial",
        });
        yield {
          type: "partial",
          provider: geminiProviderID,
          model,
          result,
          metadata: result.metadata,
        };
      }

      const output = parseGeminiOutputText(accumulatedText);
      const result = normalizedScreenshotResult(request, output, {
        provider: geminiProviderID,
        parserProvider: screenshotProviderID,
        model,
        service: config.service,
        location: config.location,
        latencyMs: String(Math.round(performance.now() - startedAt)),
        "screenshotParser.stream": "final",
      });
      yield {
        type: "final",
        provider: geminiProviderID,
        model,
        result,
        usage: latestUsage,
        metadata: result.metadata,
      };
    },
  };
}

export function screenshotParseModelForRequest(request: ScreenshotParseRequest) {
  if (isDebugOverlayRequest(request)) {
    return defaultDebugOverlayScreenshotParseModel;
  }

  return defaultScreenshotParseModel;
}

function geminiRequestParameters(
  request: ScreenshotParseRequest,
  model: string,
): GenerateContentParameters {
  const profile = screenshotParseProfile(request);
  return {
    model,
    contents: [
      {
        role: "user",
        parts: [
          {
            text: screenshotParsingPrompt(request),
          },
          {
            inlineData: {
              data: request.imageBase64,
              mimeType: request.contentType,
            },
          },
        ],
      },
    ],
    config: {
      mediaResolution: profile.mediaResolution,
      responseMimeType: "application/json",
      responseSchema: geminiOutputSchema,
      temperature: 0,
      topP: 0.1,
      candidateCount: 1,
      maxOutputTokens: profile.maxOutputTokens,
      thinkingConfig: {
        thinkingBudget: 0,
      },
    },
  };
}

function screenshotParsingPrompt(request: ScreenshotParseRequest) {
  if (isDebugOverlayRequest(request)) {
    return [
      "You are a read-only UI screenshot parser for a macOS developer inspection overlay.",
      "The screenshot is a single app/window capture, never the entire desktop.",
      "Return compact JSON matching the provided schema.",
      "For this overlay profile, visibleText must be [] and formFields must be []; put readable names only in control labels.",
      "Return bounding boxes for the full visible clickable/control region, not just the text glyphs or icon pixels.",
      "Treat compound controls as one control when a symbol/icon and nearby text visually act together; the box should cover the icon, text, and full hit target.",
      "Treat standalone symbols/icons as controls when they use standard UI shapes or placement, even if there is no visible text label.",
      "For nav/sidebar/list/file rows, box the entire row target including icon, label, and selection background when visible.",
      "Always include macOS titlebar controls and toolbar controls when visible: red/yellow/green traffic lights, sidebar toggle, back/forward arrows, title actions, and top-right toolbar icons.",
      "Always include bottom composer/input controls when visible: the text input surface, add/attachment button, mode selector, model selector, mic/voice button, and send/stop button.",
      "Deliberately scan the top edge of the image from left to right for small window chrome controls, navigation icons, segmented controls, menus, status buttons, and titlebar actions.",
      "Deliberately scan the bottom edge of the image from left to right for composer/input areas, accessory icons, dropdown selectors, microphone controls, submit/stop controls, and other docked toolbars.",
      "Small circular or icon-only controls near the top or bottom edges should be included even when they have no readable text; infer a concise generic label such as close, minimize, zoom, back, forward, add, voice, submit, or stop when visually supported.",
      "Prioritize visible controls and selectable regions that are useful to draw debug boxes: buttons, icon buttons, nav/sidebar rows, tabs, menus, file rows, list rows, links, inputs, titlebar controls, and bottom composer controls.",
      "Do not include decorative backgrounds, separators, or long static prose blocks unless they are clickable/selectable regions.",
      "Prefer 25-55 high-confidence controls over an exhaustive map.",
      "Use box_2d as [ymin, xmin, ymax, xmax] normalized to 0-1000 over the full image.",
      "Use concise labels copied from visible text when possible.",
      `Image pixel size: ${request.pixelSize.width}x${request.pixelSize.height}.`,
      `Target ID: ${request.targetID ?? "unknown"}.`,
    ].join("\n");
  }

  return [
    "You are a read-only UI screenshot parser for a macOS app automation system.",
    "The screenshot is scoped to an app/window or a system-navigation surface, never the entire desktop.",
    "Extract only visible, grounded UI evidence from that scoped screenshot.",
    "Do not infer user intent, do not suggest actions, and do not return executable commands.",
    "Return JSON matching the provided schema.",
    "Be dense: return all visible navigation rows, sidebar items, tabs, buttons, icon buttons, menus, file/change rows, input fields, checkboxes, links, cards, list items, and important text regions.",
    "Treat controls as visual affordances, not only text. Many controls are a symbol/icon plus a label, a symbol inside a button shape, or an icon-only target; box the complete hit target rather than only the glyphs.",
    "Do not stop after the primary content. Include left navigation, right panels, bottom composers/toolbars, title bars, and repeated rows when visible.",
    "Use kind=listItem for selectable rows or navigation entries, kind=group for non-clickable labeled regions/cards, and kind=unknown only when no better kind fits.",
    "Prefer returning more grounded UI elements over a sparse summary. Aim for 40-120 controls on a complex desktop app screenshot when that many distinct regions are visible.",
    "visibleText should contain the most important readable text snippets, including text from controls.",
    "Use box_2d as [ymin, xmin, ymax, xmax] normalized to 0-1000 over the full image.",
    "Use concise labels copied from visible text when possible.",
    `Image pixel size: ${request.pixelSize.width}x${request.pixelSize.height}.`,
    `Screenshot scope: ${request.metadata["screenshot.scope"] ?? "targetWindow"}.`,
    `Target ID: ${request.targetID ?? "unknown"}.`,
  ].join("\n");
}

function screenshotParseProfile(request: ScreenshotParseRequest) {
  if (isDebugOverlayRequest(request)) {
    return {
      mediaResolution: MediaResolution.MEDIA_RESOLUTION_LOW,
      maxOutputTokens: 4_096,
    };
  }

  return {
    mediaResolution: MediaResolution.MEDIA_RESOLUTION_HIGH,
    maxOutputTokens: 16_384,
  };
}

function isDebugOverlayRequest(request: ScreenshotParseRequest) {
  return request.metadata.source === "debug-ui-inspection-overlay";
}

function parseGeminiOutput(rawBody: JsonValue) {
  return parseGeminiOutputText(geminiText(rawBody));
}

function parseGeminiOutputText(text: string) {
  const candidates = jsonObjectCandidates(text).reverse();
  let parsed: unknown;
  for (const candidate of candidates) {
    try {
      parsed = JSON.parse(candidate);
      break;
    } catch {
      continue;
    }
  }

  if (parsed === undefined) {
    throw new InferenceProviderError("Gemini returned invalid screenshot parser JSON.", {
      statusCode: 502,
      code: "invalid_provider_output",
    });
  }

  const output = geminiScreenshotParseOutputSchema.safeParse(parsed);
  if (!output.success) {
    throw new InferenceProviderError("Gemini screenshot parser output did not match schema.", {
      statusCode: 502,
      code: "invalid_provider_output",
      details: {
        issues: output.error.issues.map((issue) => ({
          path: issue.path.join("."),
          message: issue.message,
        })),
      },
    });
  }

  return output.data;
}

function jsonObjectCandidates(text: string) {
  const trimmed = text.trim();
  const candidates = trimmed ? [trimmed] : [];
  let objectStart = -1;
  let depth = 0;
  let inString = false;
  let escaped = false;

  for (let index = 0; index < text.length; index += 1) {
    const character = text[index];

    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (character === "\\") {
        escaped = true;
      } else if (character === "\"") {
        inString = false;
      }
      continue;
    }

    if (character === "\"") {
      inString = true;
    } else if (character === "{") {
      if (depth === 0) {
        objectStart = index;
      }
      depth += 1;
    } else if (character === "}" && depth > 0) {
      depth -= 1;
      if (depth === 0 && objectStart >= 0) {
        candidates.push(text.slice(objectStart, index + 1));
        objectStart = -1;
      }
    }
  }

  return Array.from(new Set(candidates));
}

async function streamGeminiContent(
  client: GeminiClient,
  request: ScreenshotParseRequest,
  model: string,
) {
  try {
    return await client.models.generateContentStream(
      geminiRequestParameters(request, model),
    );
  } catch (error) {
    throw geminiProviderError(error);
  }
}

function partialGeminiOutput(text: string): GeminiScreenshotParseOutput {
  const controls = extractArrayObjectTexts(text, "controls")
    .map((controlText) => {
      try {
        return JSON.parse(controlText) as unknown;
      } catch {
        return null;
      }
    })
    .map((control) => geminiScreenshotControlSchema.safeParse(control))
    .filter((control) => control.success)
    .map((control) => control.data);

  return {
    visibleText: [],
    controls,
    formFields: [],
    confidence: controls.reduce(
      (confidence, control) => Math.max(confidence, control.confidence),
      0,
    ),
  };
}

function extractArrayObjectTexts(jsonText: string, propertyName: string) {
  const propertyIndex = jsonText.indexOf(`"${propertyName}"`);
  if (propertyIndex < 0) {
    return [];
  }

  const arrayStart = jsonText.indexOf("[", propertyIndex);
  if (arrayStart < 0) {
    return [];
  }

  const objects: string[] = [];
  let objectStart = -1;
  let objectDepth = 0;
  let arrayDepth = 0;
  let inString = false;
  let escaped = false;

  for (let index = arrayStart; index < jsonText.length; index += 1) {
    const character = jsonText[index];

    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (character === "\\") {
        escaped = true;
      } else if (character === "\"") {
        inString = false;
      }
      continue;
    }

    if (character === "\"") {
      inString = true;
      continue;
    }

    if (character === "[") {
      arrayDepth += 1;
      continue;
    }

    if (character === "]") {
      arrayDepth -= 1;
      if (arrayDepth === 0) {
        break;
      }
      continue;
    }

    if (arrayDepth !== 1) {
      continue;
    }

    if (character === "{") {
      if (objectDepth === 0) {
        objectStart = index;
      }
      objectDepth += 1;
      continue;
    }

    if (character === "}") {
      objectDepth -= 1;
      if (objectDepth === 0 && objectStart >= 0) {
        objects.push(jsonText.slice(objectStart, index + 1));
        objectStart = -1;
      }
    }
  }

  return objects;
}

function geminiText(rawBody: JsonValue) {
  if (isJsonObject(rawBody) && typeof rawBody.text === "string") {
    return rawBody.text;
  }
  const candidates = isJsonObject(rawBody) && Array.isArray(rawBody.candidates)
    ? rawBody.candidates
    : [];
  const first = candidates.find(isJsonObject);
  const content = first ? first.content : undefined;
  const parts = content !== undefined && isJsonObject(content) && Array.isArray(content.parts)
    ? content.parts
    : [];
  return parts
    .filter(isJsonObject)
    .map((part) => typeof part.text === "string" ? part.text : "")
    .join("")
    .trim();
}

function geminiResponseText(response: unknown) {
  const directText = response !== null
    && typeof response === "object"
    && "text" in response
    && typeof response.text === "string"
    ? response.text
    : undefined;
  return directText ?? geminiText(toJsonValue(response));
}

function usageFromGeminiResponse(rawBody: JsonValue): JsonValue | undefined {
  if (!isJsonObject(rawBody)) {
    return undefined;
  }
  const usage = rawBody.usageMetadata ?? rawBody.usage;
  return usage === undefined ? undefined : toJsonValue(usage);
}


const geminiOutputSchema: Schema = {
  type: Type.OBJECT,
  required: ["visibleText", "controls", "formFields", "confidence"],
  properties: {
    visibleText: {
      type: Type.ARRAY,
      items: {
        type: Type.OBJECT,
        required: ["text", "confidence"],
        properties: {
          id: { type: Type.STRING },
          text: { type: Type.STRING },
          confidence: { type: Type.NUMBER, minimum: 0, maximum: 1 },
        },
      },
    },
    controls: {
      type: Type.ARRAY,
      items: {
        type: Type.OBJECT,
        required: ["label", "kind", "confidence", "box_2d"],
        properties: {
          id: { type: Type.STRING },
          label: { type: Type.STRING },
          kind: { type: Type.STRING },
          confidence: { type: Type.NUMBER, minimum: 0, maximum: 1 },
          box_2d: {
            type: Type.ARRAY,
            items: { type: Type.NUMBER, minimum: 0, maximum: 1000 },
          },
        },
      },
    },
    formFields: {
      type: Type.ARRAY,
      items: {
        type: Type.OBJECT,
        required: ["label", "isRequired", "confidence"],
        properties: {
          id: { type: Type.STRING },
          label: { type: Type.STRING },
          isRequired: { type: Type.BOOLEAN },
          currentValue: { type: Type.STRING },
          confidence: { type: Type.NUMBER, minimum: 0, maximum: 1 },
          box_2d: {
            type: Type.ARRAY,
            items: { type: Type.NUMBER, minimum: 0, maximum: 1000 },
          },
        },
      },
    },
    confidence: { type: Type.NUMBER, minimum: 0, maximum: 1 },
  },
};

export function geminiClientConfig(environment: AdapterEnvironment = process.env): {
  configured: boolean;
  options: GoogleGenAIOptions;
  service: "vertex-ai" | "gemini-api";
  location: string;
} {
  const googleCredentials = googleCredentialsFromEnvironment(environment);
  const project = googleCredentials?.project_id;
  const apiKey =
    environment.GEMINI_API_KEY?.trim()
    || environment.GOOGLE_API_KEY?.trim()
    || "";

  if (project) {
    const options: GoogleGenAIOptions = {
      vertexai: true,
      location: defaultVertexLocation,
      project,
      httpOptions: { timeout: requestTimeoutMs },
    };
    if (googleCredentials) {
      options.googleAuthOptions = {
        authClient: googleAuthClient(googleCredentials),
      };
    }
    return {
      configured: true,
      options,
      service: "vertex-ai",
      location: defaultVertexLocation,
    };
  }

  const options: GoogleGenAIOptions = {
    httpOptions: { timeout: requestTimeoutMs },
  };
  if (apiKey) {
    options.apiKey = apiKey;
  }

  return {
    configured: Boolean(apiKey),
    options,
    service: "gemini-api",
    location: "global",
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
    return new InferenceProviderError("Gemini screenshot parsing failed.", {
      statusCode: error.status,
      code: "provider_error",
      details: {
        status: error.status,
        message: error.message,
      },
    });
  }

  return new InferenceProviderError("Gemini screenshot parsing failed.", {
    details: {
      message: error instanceof Error ? error.message : "Unknown error",
    },
  });
}

function stringValue(value: JsonValue | undefined) {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

