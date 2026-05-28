import { NextResponse } from "next/server";

import {
  creditUsageHeaders,
  inferenceUsageRoutes,
  recordFailedInferenceUsage,
  recordInferenceUsage,
  requireInferenceCredits,
} from "@/lib/credits/inference";
import { withDonkeyAuth } from "@/lib/donkey-api-auth";
import { InferenceProviderError } from "@/lib/inference/providers";
import {
  checkInMemoryRateLimit,
  rateLimitResponse,
} from "@/lib/inference/rate-limit";
import { readLimitedJsonBody } from "@/lib/inference/request-body";
import {
  inferenceErrorCode,
  inferenceProviderErrorResponse,
  requireInferenceClientId,
  validationErrorResponse,
} from "@/lib/inference/responses";
import {
  createScreenshotParserProvider,
  parseScreenshot,
  parseScreenshotStream,
} from "@/lib/inference/screenshot-parsing";
import { screenshotParseRequestSchema } from "@/lib/inference/screenshot-parsing/schema";
import type { ScreenshotParseRequest } from "@/lib/inference/screenshot-parsing/schema";

export const dynamic = "force-dynamic";

const screenshotParseMaxBodyBytes = 6_250_000;
const screenshotParseRateLimit = {
  limit: 4,
  windowMs: 3_000,
};

export const POST = withDonkeyAuth(async (request) => {
  const client = requireInferenceClientId(request.donkey.clientId);
  if (!client.ok) {
    return client.response;
  }

  const rateLimit = checkInMemoryRateLimit({
    key: `${request.donkey.userId}:${client.clientId}`,
    ...screenshotParseRateLimit,
  });
  if (!rateLimit.ok) {
    return rateLimitResponse(rateLimit.retryAfterSeconds);
  }

  const body = await readLimitedJsonBody(request, screenshotParseMaxBodyBytes);
  if (!body.ok) {
    return body.response;
  }

  const parsed = screenshotParseRequestSchema.safeParse(body.json);
  if (!parsed.success) {
    return validationErrorResponse(parsed.error);
  }
  if (parsed.data.metadata["screenshot.scope"] === "desktop") {
    return NextResponse.json(
      {
        error: "Unsupported screenshot scope",
        message: "Screenshot parsing accepts app/window or system-navigation screenshots, not full-desktop captures.",
      },
      { status: 400 },
    );
  }

  const parserProvider = createScreenshotParserProvider();
  const model = parserProvider.modelForRequest(parsed.data);
  const credits = await requireInferenceCredits({
    model,
    provider: parserProvider.inferenceProvider,
    route: inferenceUsageRoutes.screenshotParse,
    userId: request.donkey.userId,
  });
  if (!credits.ok) {
    return credits.response;
  }

  if (parsed.data.stream) {
    return streamScreenshotParseResponse({
      clientId: client.clientId,
      model,
      parserProvider,
      request: parsed.data,
      userId: request.donkey.userId,
    });
  }

  try {
    const result = await parseScreenshot(parsed.data, parserProvider);
    const recordedUsage = await recordInferenceUsage({
      clientId: client.clientId,
      metadata: {
        parserProvider: parserProvider.id,
      },
      model: result.model,
      provider: result.provider,
      requestKind: "screenshot_parse",
      route: inferenceUsageRoutes.screenshotParse,
      status: "succeeded",
      usage: result.usage,
      userId: request.donkey.userId,
    });

    return NextResponse.json(result.result, {
      headers: {
        "X-Donkey-Inference-Provider": result.provider,
        "X-Donkey-Inference-Model": result.model,
        ...creditUsageHeaders(recordedUsage),
      },
    });
  } catch (error) {
    await recordFailedInferenceUsage({
      clientId: client.clientId,
      errorCode: inferenceErrorCode(error),
      metadata: {
        parserProvider: parserProvider.id,
      },
      model,
      provider: parserProvider.inferenceProvider,
      requestKind: "screenshot_parse",
      route: inferenceUsageRoutes.screenshotParse,
      userId: request.donkey.userId,
    });
    if (error instanceof InferenceProviderError) {
      return inferenceProviderErrorResponse(error);
    }

    throw error;
  }
});

function streamScreenshotParseResponse(input: {
  clientId: string;
  model: string;
  parserProvider: ReturnType<typeof createScreenshotParserProvider>;
  request: ScreenshotParseRequest;
  userId: string;
}) {
  const encoder = new TextEncoder();
  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      try {
        for await (const event of parseScreenshotStream(input.request, input.parserProvider)) {
          if (event.type === "partial") {
            controller.enqueue(encoder.encode(serverSentEvent("partial", event.result)));
            continue;
          }

          const recordedUsage = await recordInferenceUsage({
            clientId: input.clientId,
            metadata: {
              parserProvider: input.parserProvider.id,
              streaming: true,
            },
            model: event.model,
            provider: event.provider,
            requestKind: "screenshot_parse",
            route: inferenceUsageRoutes.screenshotParse,
            status: "succeeded",
            usage: event.usage,
            userId: input.userId,
          });
          controller.enqueue(
            encoder.encode(
              serverSentEvent("final", {
                ...event.result,
                metadata: {
                  ...event.result.metadata,
                  ...creditUsageHeaders(recordedUsage),
                },
              }),
            ),
          );
        }
      } catch (error) {
        await recordFailedInferenceUsage({
          clientId: input.clientId,
          errorCode: inferenceErrorCode(error),
          metadata: {
            parserProvider: input.parserProvider.id,
            streaming: true,
          },
          model: input.model,
          provider: input.parserProvider.inferenceProvider,
          requestKind: "screenshot_parse",
          route: inferenceUsageRoutes.screenshotParse,
          userId: input.userId,
        });
        controller.enqueue(
          encoder.encode(
            serverSentEvent("error", {
              error: inferenceErrorCode(error),
              message: error instanceof Error ? error.message : "Screenshot parsing failed.",
              details: error instanceof InferenceProviderError ? error.details : null,
            }),
          ),
        );
      } finally {
        controller.close();
      }
    },
  });

  return new Response(stream, {
    headers: {
      "Cache-Control": "no-cache, no-transform",
      "Connection": "keep-alive",
      "Content-Type": "text/event-stream; charset=utf-8",
      "X-Accel-Buffering": "no",
      "X-Donkey-Inference-Model": input.model,
      "X-Donkey-Inference-Provider": input.parserProvider.inferenceProvider,
    },
  });
}

function serverSentEvent(event: string, data: unknown) {
  return `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
}
