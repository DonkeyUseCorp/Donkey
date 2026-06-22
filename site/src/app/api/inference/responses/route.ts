import { NextResponse } from "next/server";

import {
  creditErrorResponse,
  creditUsageHeaders,
  inferenceUsageRoutes,
  recordFailedInferenceUsage,
  recordInferenceUsage,
  requireInferenceCredits,
} from "@/lib/credits/inference";
import { createProviderRegistry } from "@/lib/inference/router";
import { isJsonObject, toJsonValue } from "@/lib/inference/json";
import {
  inferenceErrorCode,
  inferenceProviderErrorResponse,
  requireInferenceClientId,
  validationErrorResponse,
} from "@/lib/inference/responses";
import { InferenceProviderError } from "@/lib/inference/providers";
import type { JsonObject, JsonValue } from "@/lib/inference/providers";
import { responseCreateRequestSchema } from "@/lib/inference/schemas";
import {
  shouldBypassDonkeyInferenceCredits,
  withDonkeyAuth,
} from "@/lib/donkey-api-auth";

export const dynamic = "force-dynamic";

export const POST = withDonkeyAuth(async (request) => {
  const client = requireInferenceClientId(request.donkey.clientId);
  if (!client.ok) {
    return client.response;
  }

  const parsed = responseCreateRequestSchema.safeParse(await request.json());
  if (!parsed.success) {
    return validationErrorResponse(parsed.error);
  }

  const requestedModel =
    typeof parsed.data.body.model === "string" && parsed.data.body.model.trim()
      ? parsed.data.body.model.trim()
      : "unknown";
  const bypassCredits = shouldBypassDonkeyInferenceCredits(request.donkey);
  if (!bypassCredits) {
    const credits = await requireInferenceCredits({
      model: requestedModel,
      provider: parsed.data.donkeyProvider,
      route: inferenceUsageRoutes.responses,
      userId: request.donkey.userId,
    });
    if (!credits.ok) {
      return credits.response;
    }
  }

  const debugInspection = isDebugUIInspectionRequest(parsed.data.body);
  const debugInspectionStartedAt = performance.now();
  if (debugInspection) {
    console.info(
      [
        "[debug-ui-inspection] start",
        `at=${new Date().toISOString()}`,
        `provider=${parsed.data.donkeyProvider ?? "default"}`,
        `requestedModel=${requestedModel}`,
      ].join(" "),
    );
  }

  let failedUsageProvider = parsed.data.donkeyProvider ?? "default";

  try {
    const registry = createProviderRegistry();
    const provider = registry.responsesProvider(parsed.data);
    failedUsageProvider = provider.id;
    const providerStartedAt = performance.now();
    const result = await provider.createResponse?.(parsed.data);
    if (!result) {
      if (!bypassCredits) {
        await recordFailedInferenceUsage({
          clientId: client.clientId,
          errorCode: "responses_unavailable",
          model: requestedModel,
          provider: failedUsageProvider,
          requestKind: "responses",
          route: inferenceUsageRoutes.responses,
          userId: request.donkey.userId,
        });
      }

      return NextResponse.json(
        {
          error: "Responses unavailable",
        },
        { status: 503 },
      );
    }

    let usageHeaders: Record<string, string> = {};
    if (bypassCredits) {
      usageHeaders["X-Donkey-Dev-Auth-Bypass"] = "true";
    } else {
      const recordedUsage = await recordInferenceUsage({
        clientId: client.clientId,
        model: result.model,
        provider: result.provider,
        requestKind: "responses",
        route: inferenceUsageRoutes.responses,
        status: "succeeded",
        usage: result.usage,
        userId: request.donkey.userId,
      });
      usageHeaders = creditUsageHeaders(recordedUsage);
    }

    if (debugInspection) {
      const providerEndedAt = performance.now();
      console.info(
        [
          "[debug-ui-inspection] end",
          `at=${new Date().toISOString()}`,
          `provider=${result.provider}`,
          `model=${result.model}`,
          `providerMs=${Math.round(providerEndedAt - providerStartedAt)}`,
          `totalMs=${Math.round(providerEndedAt - debugInspectionStartedAt)}`,
          debugInspectionResultSummary(result.body),
        ].join(" "),
      );
    }

    return NextResponse.json(result.body, {
      headers: {
        "X-Donkey-Inference-Provider": result.provider,
        "X-Donkey-Inference-Model": result.model,
        ...usageHeaders,
      },
    });
  } catch (error) {
    if (!bypassCredits) {
      await recordFailedInferenceUsage({
        clientId: client.clientId,
        errorCode: inferenceErrorCode(error),
        model: requestedModel,
        provider: failedUsageProvider,
        requestKind: "responses",
        route: inferenceUsageRoutes.responses,
        userId: request.donkey.userId,
      });
    }
    const creditResponse = creditErrorResponse(error);
    if (creditResponse) {
      return creditResponse;
    }
    if (error instanceof InferenceProviderError) {
      return inferenceProviderErrorResponse(error);
    }

    throw error;
  }
});

function isDebugUIInspectionRequest(body: JsonObject) {
  if (!Array.isArray(body.tools)) {
    return false;
  }

  return body.tools.some((tool) => {
    return isJsonObject(tool) && tool.type === "donkey_debug_ui_inspection";
  });
}

function debugInspectionResultSummary(body: JsonValue) {
  const object: JsonObject = isJsonObject(body) ? body : {};
  const outputText = typeof object.output_text === "string" ? object.output_text : "";
  const elementCount =
    elementCountFromFrame(object) ??
    elementCountFromOutputText(outputText);

  return [
    `outputTextChars=${outputText.length}`,
    `elements=${elementCount ?? "unknown"}`,
  ].join(" ");
}

function elementCountFromOutputText(outputText: string) {
  if (!outputText.trim()) {
    return null;
  }

  try {
    return elementCountFromFrame(toJsonValue(JSON.parse(outputText)));
  } catch {
    return null;
  }
}

function elementCountFromFrame(value: JsonValue) {
  if (!isJsonObject(value) || !Array.isArray(value.elements)) {
    return null;
  }

  return value.elements.length;
}
