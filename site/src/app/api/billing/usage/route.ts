import { NextResponse } from "next/server";

import { inferenceUsageRoutes } from "@/lib/credits/inference";
import {
  donkeySessionUserId,
  unauthorizedResponse,
  withDonkeyAuth,
} from "@/lib/donkey-api-auth";
import { prisma } from "@/lib/prisma";

export const dynamic = "force-dynamic";

// Current-period Vision API call usage vs quota, plus recent API calls, for the
// dashboard. Reads the authoritative per-period counter on the subscription;
// the recent list is independent so it runs in parallel.
export const GET = withDonkeyAuth(async (request) => {
  const userId = donkeySessionUserId(request);
  if (!userId) {
    return unauthorizedResponse();
  }

  const [subscription, recent] = await Promise.all([
    prisma.visionApiSubscription.findUnique({ where: { userId } }),
    prisma.inferenceUsageEvent.findMany({
      orderBy: { createdAt: "desc" },
      select: {
        createdAt: true,
        model: true,
        requestKind: true,
        status: true,
      },
      take: 20,
      // billingStatus "included" = the API-key path, so this list never mixes
      // in the user's Mac-app (credit-billed) vision calls.
      where: {
        billingStatus: "included",
        route: inferenceUsageRoutes.vision,
        userId,
      },
    }),
  ]);

  const limit = subscription?.monthlyCallQuota ?? 0;
  const used = subscription?.periodCallCount ?? 0;

  return NextResponse.json({
    limit,
    periodEnd: subscription?.currentPeriodEnd?.toISOString() ?? null,
    periodStart: subscription?.currentPeriodStart?.toISOString() ?? null,
    recent: recent.map((event) => ({
      createdAt: event.createdAt.toISOString(),
      model: event.model,
      requestKind: event.requestKind,
      status: event.status,
    })),
    remaining: Math.max(0, limit - used),
    used,
  });
});
