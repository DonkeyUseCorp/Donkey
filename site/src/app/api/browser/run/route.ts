import { NextResponse } from "next/server";
import { z } from "zod";

import {
  browserUseDefaultMaxCostUsd,
  browserUseDefaultModel,
  browserUseProvider,
  getBrowserUse,
} from "@/lib/browser/client";
import {
  creditUsageHeaders,
  inferenceUsageRoutes,
  recordInferenceUsage,
  requireInferenceCredits,
} from "@/lib/credits/inference";
import { withDonkeyAuth } from "@/lib/donkey-api-auth";
import {
  requireInferenceClientId,
  validationErrorResponse,
} from "@/lib/inference/responses";

export const dynamic = "force-dynamic";
// The run executes server-side to completion (the SDK polls Browser Use here, not
// the app), so the function must be allowed to run long. maxCostUsd bounds the
// task so it finishes well within this.
export const maxDuration = 300;

const runSchema = z.object({
  task: z.string().min(1),
  startUrl: z.string().url().optional(),
  structuredOutputSchema: z.record(z.string(), z.unknown()).optional(),
});

// Run an agentic browser task and return its result. The backend runs it to
// completion and charges credits here (by step count), so charging never depends
// on the client polling.
export const POST = withDonkeyAuth(async (request) => {
  const client = requireInferenceClientId(request.donkey.clientId);
  if (!client.ok) return client.response;

  const parsed = runSchema.safeParse(await request.json());
  if (!parsed.success) return validationErrorResponse(parsed.error);

  const credits = await requireInferenceCredits({
    userId: request.donkey.userId,
    route: inferenceUsageRoutes.browserRun,
    provider: browserUseProvider,
    model: browserUseDefaultModel,
  });
  if (!credits.ok) return credits.response;

  // v3 has no separate start-url field; fold it into the task prompt.
  const task = parsed.data.startUrl
    ? `Start at ${parsed.data.startUrl}. ${parsed.data.task}`
    : parsed.data.task;

  const session = await getBrowserUse().run(task, {
    model: browserUseDefaultModel,
    maxCostUsd: browserUseDefaultMaxCostUsd,
    timeout: (maxDuration - 20) * 1000,
    ...(parsed.data.structuredOutputSchema
      ? { outputSchema: parsed.data.structuredOutputSchema }
      : {}),
  });

  const stepCount = session.stepCount ?? 0;
  // Browser Use bills steps even on failure, so charge regardless of success.
  const recorded = await recordInferenceUsage({
    userId: request.donkey.userId,
    clientId: client.clientId,
    route: inferenceUsageRoutes.browserRun,
    requestKind: "browser_automation",
    provider: browserUseProvider,
    model: browserUseDefaultModel,
    status: "succeeded",
    usage: { generationCount: stepCount },
    metadata: { isTaskSuccessful: session.isTaskSuccessful ?? null },
  });

  const output: unknown = session.output ?? null;
  const structured =
    output !== null && typeof output === "object"
      ? JSON.stringify(output)
      : null;
  const text = typeof output === "string" ? output : null;

  return NextResponse.json(
    {
      status: session.status,
      done: true,
      isTaskSuccessful: session.isTaskSuccessful ?? null,
      text,
      structured,
      recordingUrl: session.recordingUrls?.[0] ?? null,
      liveUrl: session.liveUrl ?? null,
      stepCount,
      lastStepSummary: session.lastStepSummary ?? null,
    },
    { headers: creditUsageHeaders(recorded) },
  );
});
