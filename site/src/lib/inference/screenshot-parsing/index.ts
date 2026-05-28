import { InferenceProviderError } from "@/lib/inference/providers";
import { createGeminiFlashScreenshotParser } from "@/lib/inference/screenshot-parsing/gemini-flash";
import type {
  ScreenshotParserProvider,
  ScreenshotParserProviderResult,
  ScreenshotParserProviderStreamEvent,
} from "@/lib/inference/screenshot-parsing/types";
import type { ScreenshotParseRequest } from "@/lib/inference/screenshot-parsing/schema";

export function createScreenshotParserProvider(): ScreenshotParserProvider {
  return createGeminiFlashScreenshotParser();
}

export async function parseScreenshot(
  request: ScreenshotParseRequest,
  provider: ScreenshotParserProvider = createScreenshotParserProvider(),
): Promise<ScreenshotParserProviderResult> {
  if (!provider.configured) {
    throw new InferenceProviderError("Screenshot parser provider is not configured.", {
      statusCode: 503,
      code: "missing_provider_credentials",
      details: {
        provider: provider.id,
      },
    });
  }

  return provider.parse(request);
}

export async function* parseScreenshotStream(
  request: ScreenshotParseRequest,
  provider: ScreenshotParserProvider = createScreenshotParserProvider(),
): AsyncGenerator<ScreenshotParserProviderStreamEvent> {
  if (!provider.configured) {
    throw new InferenceProviderError("Screenshot parser provider is not configured.", {
      statusCode: 503,
      code: "missing_provider_credentials",
      details: {
        provider: provider.id,
      },
    });
  }

  if (!provider.stream) {
    const result = await provider.parse(request);
    yield {
      type: "final",
      provider: result.provider,
      model: result.model,
      result: result.result,
      usage: result.usage,
      metadata: result.metadata,
    };
    return;
  }

  yield* provider.stream(request);
}
