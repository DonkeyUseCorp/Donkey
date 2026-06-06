import { NextResponse } from "next/server";

import { isActiveVisionStatus } from "@/lib/billing/vision-subscription";
import {
  donkeySessionUserId,
  unauthorizedResponse,
  withDonkeyAuth,
} from "@/lib/donkey-api-auth";
import { prisma } from "@/lib/prisma";

export const dynamic = "force-dynamic";

// Current Vision API subscription for the signed-in user, or null. Returns
// isActive so clients don't re-derive the active-status rule.
export const GET = withDonkeyAuth(async (request) => {
  const userId = donkeySessionUserId(request);
  if (!userId) {
    return unauthorizedResponse();
  }

  const subscription = await prisma.visionApiSubscription.findUnique({
    where: { userId },
  });

  if (!subscription?.stripeSubscriptionId) {
    return NextResponse.json({ subscription: null });
  }

  return NextResponse.json({
    subscription: {
      cancelAtPeriodEnd: subscription.cancelAtPeriodEnd,
      currentPeriodEnd: subscription.currentPeriodEnd?.toISOString() ?? null,
      isActive: isActiveVisionStatus(subscription.status),
      monthlyCallQuota: subscription.monthlyCallQuota,
      planKey: subscription.planKey,
      status: subscription.status,
    },
  });
});
