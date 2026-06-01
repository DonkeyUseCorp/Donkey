import { toJsonObject } from "@/lib/inference/json";
import type {
  GeminiScreenshotParseOutput,
  HotLoopRectJSON,
  ScreenshotParseRequest,
} from "@/lib/inference/screenshot-parsing/schema";
import type { ScreenshotParserResult } from "@/lib/inference/screenshot-parsing/types";

// Provider-agnostic normalization shared by the screenshot-parsing providers
// (gemini-flash, vision). Turns the common parse output — visibleText,
// controls with box_2d in [ymin, xmin, ymax, xmax]/1000 space, and form fields
// — into the ScreenshotParserResult contract, stamping each result with its
// originating `source`.
export function normalizedScreenshotResult(
  request: ScreenshotParseRequest,
  output: GeminiScreenshotParseOutput,
  metadata: Record<string, string>,
  source = "gemini-screenshot-parser",
): ScreenshotParserResult {
  const visibleText = output.visibleText.reduce<Record<string, string>>((result, item, index) => {
    const key = item.id?.trim() || (index === 0 ? "visibleText" : `visibleText.${index + 1}`);
    result[key] = item.text;
    return result;
  }, {});

  const usedControlIDs = new Set<string>();
  const controls = output.controls.map((control) => {
    // Opaque, unique-per-result control id. searchField keeps the well-known
    // "search" id that the local-app action plan defaults to.
    const controlID = control.kind === "searchField"
      ? "search"
      : uniqueShortID(usedControlIDs);
    return {
      id: controlID,
      label: control.label,
      kind: control.kind,
      frame: rectFromGeminiBox(control.box_2d, request.pixelSize.width, request.pixelSize.height),
      confidence: clamp01(control.confidence),
      metadata: {
        controlID,
        segmentID: controlID,
        source,
        boxFormat: "ymin,xmin,ymax,xmax/1000",
        "localUIElement.actionEligibility": "guardedAction",
        directInputActionsAllowed: "true",
      },
    };
  });

  const formFields = output.formFields.map((field, index) => {
    const id = field.id?.trim() || `form-field-${index + 1}`;
    return {
      id,
      label: field.label,
      isRequired: field.isRequired,
      currentValue: field.currentValue ?? null,
      metadata: {
        source,
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
      "runtime.backend": source,
      "directInputActionsAllowed": "true",
      "screenshotParser.controlCount": String(controls.length),
      "screenshotParser.formFieldCount": String(formFields.length),
    }),
  };
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

function uniqueShortID(used: Set<string>): string {
  let id = shortID();
  while (used.has(id)) {
    id = shortID();
  }
  used.add(id);
  return id;
}

function shortID(): string {
  return Math.random().toString(36).slice(2, 8).padEnd(6, "0");
}

function clamp01(value: number) {
  return clamp(value, 0, 1);
}

function clamp(value: number, lower: number, upper: number) {
  return Math.min(Math.max(value, lower), upper);
}
