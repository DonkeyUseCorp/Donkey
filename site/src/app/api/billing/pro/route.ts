import { NextResponse } from "next/server";

import { getActiveProSubscription } from "@/lib/billing/pro-subscription";
import { creditMicrosToString, zeroCreditMicros } from "@/lib/credits/amounts";
import { creditGrantUnit } from "@/lib/credits/inference";
import { withDonkeyAuth } from "@/lib/donkey-api-auth";
import { prisma } from "@/lib/prisma";

export const dynamic = "force-dynamic";

// Pro subscription status for the settings UI, plus how much of this period's
// included allowance is left — the remaining balance on the active
// "pro_subscription" grant(s).
export const GET = withDonkeyAuth(async (request) => {
  const userId = request.donkey.userId;
  const now = new Date();

  const [subscription, grants] = await Promise.all([
    getActiveProSubscription(userId),
    prisma.userCreditGrant.findMany({
      select: { remainingAmountMicros: true },
      where: {
        OR: [{ expiresAt: null }, { expiresAt: { gt: now } }],
        remainingAmountMicros: { gt: zeroCreditMicros },
        source: "pro_subscription",
        status: "active",
        unit: creditGrantUnit,
        userId,
      },
    }),
  ]);

  const allowanceRemainingMicros = grants.reduce(
    (sum, grant) => sum + grant.remainingAmountMicros,
    zeroCreditMicros,
  );

  return NextResponse.json({
    allowanceRemaining: creditMicrosToString(allowanceRemainingMicros),
    cancelAtPeriodEnd: subscription?.cancelAtPeriodEnd ?? false,
    currentPeriodEnd: subscription?.currentPeriodEnd?.toISOString() ?? null,
    isActive: Boolean(subscription),
    monthlyAllowance: subscription
      ? creditMicrosToString(subscription.monthlyAllowanceMicros)
      : null,
    status: subscription?.status ?? null,
  });
});
