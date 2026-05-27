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

import { ensureConfigured } from "@/lib/inference/http";
import {
  isJsonObject,
  toJsonObject,
  toJsonValue,
} from "@/lib/inference/json";
import {
  InferenceProviderError,
  type JsonObject,
  type JsonValue,
} from "@/lib/inference/providers";
import {
  geminiScreenshotParseOutputSchema,
  type GeminiScreenshotParseOutput,
  type HotLoopRectJSON,
  type ScreenshotParseRequest,
} from "@/lib/inference/screenshot-parsing/schema";
import type {
  ScreenshotParserProvider,
  ScreenshotParserProviderResult,
  ScreenshotParserResult,
} from "@/lib/inference/screenshot-parsing/types";

type AdapterEnvironment = Record<string, string | undefined>;
type GeminiClient = Pick<GoogleGenAI, "models">;
type GeminiClientFactory = (options: GoogleGenAIOptions) => GeminiClient;

const geminiProviderID = "gemini";
const screenshotProviderID = "gemini-flash";
const defaultScreenshotParseModel = "gemini-2.5-flash";
const defaultDebugOverlayScreenshotParseModel = "gemini-2.5-flash";
const defaultVertexLocation = "global";
const vertexAIScope = "https://www.googleapis.com/auth/cloud-platform";

export function createGeminiFlashScreenshotParser(
  environment: AdapterEnvironment = process.env,
  clientFactory: GeminiClientFactory = (options) => new GoogleGenAI(options),
): ScreenshotParserProvider {
  const config = geminiClientConfig(environment);

  return {
    configured: config.configured,
    async parse(request) {
      ensureConfigured(config.configured);
      const client = clientFactory(config.options);
      const model = screenshotParseModelForRequest(request, environment);
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
  };
}

export function screenshotParseModelForRequest(
  request: ScreenshotParseRequest,
  environment: AdapterEnvironment = process.env,
) {
  if (isDebugOverlayRequest(request)) {
    return environment.GEMINI_SCREENSHOT_PARSE_DEBUG_MODEL?.trim()
      || environment.GEMINI_SCREENSHOT_PARSE_MODEL?.trim()
      || defaultDebugOverlayScreenshotParseModel;
  }

  return environment.GEMINI_SCREENSHOT_PARSE_MODEL?.trim()
    || defaultScreenshotParseModel;
}

export function normalizedScreenshotResult(
  request: ScreenshotParseRequest,
  output: GeminiScreenshotParseOutput,
  metadata: Record<string, string>,
): ScreenshotParserResult {
  const visibleText = output.visibleText.reduce<Record<string, string>>((result, item, index) => {
    const key = item.id?.trim() || (index === 0 ? "visibleText" : `visibleText.${index + 1}`);
    result[key] = item.text;
    return result;
  }, {});

  const controls = output.controls.map((control, index) => {
    const id = control.id?.trim() || `gemini-control-${index + 1}`;
    return {
      id,
      label: control.label,
      kind: control.kind,
      frame: rectFromGeminiBox(control.box_2d, request.pixelSize.width, request.pixelSize.height),
      confidence: clamp01(control.confidence),
      metadata: {
        controlID: id,
        source: "gemini-screenshot-parser",
        boxFormat: "ymin,xmin,ymax,xmax/1000",
      },
    };
  });

  const formFields = output.formFields.map((field, index) => {
    const id = field.id?.trim() || `gemini-form-field-${index + 1}`;
    return {
      id,
      label: field.label,
      isRequired: field.isRequired,
      currentValue: field.currentValue ?? null,
      metadata: {
        source: "gemini-screenshot-parser",
        confidence: String(clamp01(field.confidence)),
      },
    };
  });

  return {
    visibleText,
    controls,
    formFields,
    confidence: clamp01(output.confidence || controls.map((control) => control.confidence).reduce(
      (max, value) => Math.max(max, value),
      0,
    )),
    metadata: toJsonObject({
      ...metadata,
      "runtime.backend": "gemini-screenshot-parser",
      "directInputActionsAllowed": "false",
      "screenshotParser.controlCount": String(controls.length),
      "screenshotParser.formFieldCount": String(formFields.length),
    }),
  };
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
  return request.metadata.source === "debug-ui-inspection-overlay"
    || request.metadata.provider === "gemini";
}

function parseGeminiOutput(rawBody: JsonValue) {
  const text = geminiText(rawBody);
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
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

export function rectFromGeminiBox(
  box: [number, number, number, number],
  imageWidth: number,
  imageHeight: number,
): HotLoopRectJSON | null {
  const [ymin, xmin, ymax, xmax] = box;
  const x1 = clamp(xmin, 0, 1000) / 1000 * imageWidth;
  const y1 = clamp(ymin, 0, 1000) / 1000 * imageHeight;
  const x2 = clamp(xmax, 0, 1000) / 1000 * imageWidth;
  const y2 = clamp(ymax, 0, 1000) / 1000 * imageHeight;
  const width = Math.max(0, x2 - x1);
  const height = Math.max(0, y2 - y1);
  if (width <= 0 || height <= 0) {
    return null;
  }

  return {
    origin: {
      x: x1,
      y: y1,
      space: "window",
    },
    size: {
      width,
      height,
      space: "window",
    },
  };
}

function usageFromGeminiResponse(rawBody: JsonValue): JsonValue | undefined {
  if (!isJsonObject(rawBody)) {
    return undefined;
  }
  const usage = rawBody.usageMetadata ?? rawBody.usage;
  return usage === undefined ? undefined : toJsonValue(usage);
}

function clamp01(value: number) {
  return clamp(value, 0, 1);
}

function clamp(value: number, lower: number, upper: number) {
  return Math.min(Math.max(value, lower), upper);
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

function geminiClientConfig(environment: AdapterEnvironment): {
  configured: boolean;
  options: GoogleGenAIOptions;
  service: "vertex-ai" | "gemini-api";
  location: string;
} {
  const apiVersion = environment.GEMINI_API_VERSION?.trim() || undefined;
  const timeout = numberFromString(environment.GEMINI_TIMEOUT_MS);
  const httpOptions: GoogleGenAIOptions["httpOptions"] | undefined =
    timeout === undefined ? undefined : { timeout };
  const googleCredentials = googleCredentialsFromEnvironment(environment);
  const project = googleCredentials?.project_id;
  const apiKey =
    environment.GEMINI_API_KEY?.trim()
    || environment.GOOGLE_API_KEY?.trim()
    || "";

  if (project) {
    const location = environment.GEMINI_VERTEX_LOCATION?.trim()
      || environment.GOOGLE_VERTEX_LOCATION?.trim()
      || defaultVertexLocation;
    const options: GoogleGenAIOptions = {
      vertexai: true,
      location,
      project,
    };
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
      configured: true,
      options,
      service: "vertex-ai",
      location,
    };
  }

  const options: GoogleGenAIOptions = {};
  if (apiKey) {
    options.apiKey = apiKey;
  }
  if (apiVersion) {
    options.apiVersion = apiVersion;
  }
  if (httpOptions) {
    options.httpOptions = httpOptions;
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

function numberFromString(value: string | undefined) {
  if (!value) {
    return undefined;
  }
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : undefined;
}
