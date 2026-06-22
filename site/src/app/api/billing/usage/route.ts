import { NextResponse } from "next/server";

import { Prisma } from "@/generated/prisma/client";

import { creditMicrosToString } from "@/lib/credits/amounts";
import { readInferenceUsageBreakdown } from "@/lib/credits/inference";
import { visionCallGrantRemaining } from "@/lib/credits/vision-grants";
import {
  donkeySessionUserId,
  unauthorizedResponse,
  withDonkeyAuth,
} from "@/lib/donkey-api-auth";
import { prisma } from "@/lib/prisma";

export const dynamic = "force-dynamic";

// Up to 5 pages of 25 in the usage tab — fetched per product so a busy product
// can't starve the other tab out of the recent window.
const recentPerProduct = 125;

const recentSelect = {
  billingStatus: true,
  createdAt: true,
  creditCostMicros: true,
  errorCode: true,
  model: true,
  normalizedUsage: true,
  requestKind: true,
  status: true,
} satisfies Prisma.InferenceUsageEventSelect;

type RecentEvent = Prisma.InferenceUsageEventGetPayload<{
  select: typeof recentSelect;
}>;

function toRecentCall(event: RecentEvent, product: "app" | "vision") {
  return {
    billingStatus: event.billingStatus,
    // Credits are dollar-denominated (1 credit = $1), so this string is USD.
    costCredits: creditMicrosToString(event.creditCostMicros),
    createdAt: event.createdAt.toISOString(),
    errorCode: event.errorCode,
    model: event.model,
    product,
    requestKind: event.requestKind,
    status: event.status,
    // Per-call token breakdown — what actually drove the cost. Large input =
    // long question/context; large output = long answer.
    usage: readInferenceUsageBreakdown(event.normalizedUsage),
  };
}

// Current-period Vision API call usage vs quota, plus recent calls, for the
// settings UI. "included" billingStatus is the third-party Vision API (API-key)
// product; everything else is app usage billed to the user's credits — including
// the app's own vision_parse calls on the same route. Fetching the two products
// separately keeps each tab's history independent.
export const GET = withDonkeyAuth(async (request) => {
  const userId = donkeySessionUserId(request);
  if (!userId) {
    return unauthorizedResponse();
  }

  const [subscription, appRecent, visionRecent, extraRemaining] =
    await Promise.all([
      prisma.visionApiSubscription.findUnique({ where: { userId } }),
      prisma.inferenceUsageEvent.findMany({
        orderBy: { createdAt: "desc" },
        select: recentSelect,
        take: recentPerProduct,
        where: { billingStatus: { not: "included" }, userId },
      }),
      prisma.inferenceUsageEvent.findMany({
        orderBy: { createdAt: "desc" },
        select: recentSelect,
        take: recentPerProduct,
        where: { billingStatus: "included", userId },
      }),
      // One-time vision-call grants (signup bonus, top-ups) on top of any plan.
      visionCallGrantRemaining(userId),
    ]);

  const limit = subscription?.monthlyCallQuota ?? 0;
  const used = subscription?.periodCallCount ?? 0;

  return NextResponse.json({
    // Extra calls from grants, spent after the subscription quota runs out.
    extraRemaining: Number(extraRemaining),
    limit,
    periodEnd: subscription?.currentPeriodEnd?.toISOString() ?? null,
    periodStart: subscription?.currentPeriodStart?.toISOString() ?? null,
    recent: [
      ...appRecent.map((event) => toRecentCall(event, "app")),
      ...visionRecent.map((event) => toRecentCall(event, "vision")),
    ],
    remaining: Math.max(0, limit - used),
    used,
  });
});
