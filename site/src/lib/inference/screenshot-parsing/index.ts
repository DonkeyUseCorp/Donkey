import { InferenceProviderError } from "@/lib/inference/providers";
import {
  createGeminiFlashScreenshotParser,
  screenshotParseModelForRequest,
} from "@/lib/inference/screenshot-parsing/gemini-flash";
import type {
  ScreenshotParserProvider,
  ScreenshotParserProviderResult,
} from "@/lib/inference/screenshot-parsing/types";
import type { ScreenshotParseRequest } from "@/lib/inference/screenshot-parsing/schema";

export function createScreenshotParserProvider(): ScreenshotParserProvider {
  return createGeminiFlashScreenshotParser();
}

export { screenshotParseModelForRequest };

export async function parseScreenshot(
  request: ScreenshotParseRequest,
  provider: ScreenshotParserProvider = createScreenshotParserProvider(),
): Promise<ScreenshotParserProviderResult> {
  if (!provider.configured) {
    throw new InferenceProviderError("Screenshot parser provider is not configured.", {
      statusCode: 503,
      code: "missing_provider_credentials",
      details: {
        provider: "gemini-flash",
      },
    });
  }

  return provider.parse(request);
}
