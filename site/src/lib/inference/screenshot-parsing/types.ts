import type { JsonObject, JsonValue } from "@/lib/inference/providers";
import type {
  HotLoopRectJSON,
  ScreenshotParseRequest,
} from "@/lib/inference/screenshot-parsing/schema";

export type ScreenshotParserResult = {
  visibleText: Record<string, string>;
  controls: ScreenshotParserControl[];
  formFields: ScreenshotParserFormField[];
  confidence: number;
  metadata: JsonObject;
};

export type ScreenshotParserControl = {
  id: string;
  label: string;
  kind: string;
  frame: HotLoopRectJSON | null;
  confidence: number;
  metadata: Record<string, string>;
};

export type ScreenshotParserFormField = {
  id: string;
  label: string;
  isRequired: boolean;
  currentValue?: string | null;
  metadata: Record<string, string>;
};

export type ScreenshotParserProviderResult = {
  provider: string;
  model: string;
  result: ScreenshotParserResult;
  usage?: JsonValue;
  metadata: JsonObject;
};

export type ScreenshotParserProvider = {
  configured: boolean;
  parse: (request: ScreenshotParseRequest) => Promise<ScreenshotParserProviderResult>;
};
