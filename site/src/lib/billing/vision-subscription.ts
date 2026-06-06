import type { VisionApiSubscription } from "@/generated/prisma/client";
import { prisma } from "@/lib/prisma";

// Stripe subscription statuses that grant Vision API access.
const activeStatuses = new Set(["active", "trialing"]);

export type ActiveVisionSubscription = VisionApiSubscription;

export function isActiveVisionStatus(status: string) {
  return activeStatuses.has(status);
}

export async function getActiveVisionSubscription(
  userId: string,
): Promise<ActiveVisionSubscription | null> {
  const subscription = await prisma.visionApiSubscription.findUnique({
    where: { userId },
  });
  if (!subscription || !isActiveVisionStatus(subscription.status)) {
    return null;
  }

  return subscription;
}

// Atomically reserve one call against the monthly quota. The conditional
// UPDATE only increments when the row is still under quota, so concurrent
// requests can never push periodCallCount past monthlyCallQuota — the count and
// the check are a single statement. Returns the remaining calls after this one.
export async function reserveVisionApiCall(input: {
  userId: string;
  monthlyCallQuota: number;
}) {
  const reserved = await prisma.visionApiSubscription.updateMany({
    data: { periodCallCount: { increment: 1 } },
    where: {
      periodCallCount: { lt: input.monthlyCallQuota },
      userId: input.userId,
    },
  });

  if (reserved.count === 0) {
    return { ok: false as const };
  }

  const row = await prisma.visionApiSubscription.findUnique({
    select: { periodCallCount: true },
    where: { userId: input.userId },
  });
  const used = row?.periodCallCount ?? input.monthlyCallQuota;

  return {
    ok: true as const,
    remaining: Math.max(0, input.monthlyCallQuota - used),
  };
}

// Release a previously reserved call when the request ultimately fails, so a
// failed parse doesn't consume the developer's quota (mirrors how the credit
// path only charges successful calls). Never drops below zero.
export async function releaseVisionApiCall(userId: string) {
  await prisma.visionApiSubscription.updateMany({
    data: { periodCallCount: { decrement: 1 } },
    where: { periodCallCount: { gt: 0 }, userId },
  });
}
