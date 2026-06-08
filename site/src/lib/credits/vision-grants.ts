import { Prisma } from "@/generated/prisma/client";

import { zeroCreditMicros } from "@/lib/credits/amounts";
import { grantCredits, visionCallGrantUnit } from "@/lib/credits/inference";
import { prisma } from "@/lib/prisma";

// Vision-call grants live in UserCreditGrant under unit="vision_call": an
// off-balance integer count (stored in remainingAmountMicros) that the dollar
// credit engine never touches. Consumption here is the *only* path that reads
// these rows, so the two denominations can never cross.

const oneCall = BigInt(1);
const maxReserveAttempts = 5;

function activeVisionGrantWhere(
  userId: string,
  now: Date,
): Prisma.UserCreditGrantWhereInput {
  return {
    remainingAmountMicros: { gt: zeroCreditMicros },
    status: "active",
    unit: visionCallGrantUnit,
    userId,
    OR: [{ expiresAt: null }, { expiresAt: { gt: now } }],
  };
}

// Grant a one-time allotment of Vision API calls (signup bonus, promo, support
// comp). Idempotent via (userId, unit, source, sourceId); optionally expiring.
export async function grantVisionCalls(input: {
  userId: string;
  calls: number;
  source: string;
  sourceId?: string;
  expiresAt?: Date;
  description?: string;
}) {
  if (!Number.isInteger(input.calls) || input.calls <= 0) {
    throw new Error("Vision call grants must be a positive integer.");
  }

  return grantCredits({
    amountMicros: BigInt(input.calls),
    description: input.description,
    expiresAt: input.expiresAt,
    source: input.source,
    sourceId: input.sourceId,
    unit: visionCallGrantUnit,
    userId: input.userId,
  });
}

// Flip expired vision-call grants to "expired". These grants never moved the
// dollar balance, so a plain status update is the whole story (unlike dollar
// expiry, which must also decrement balanceMicros).
export async function expireVisionCallGrants(userId: string, now = new Date()) {
  await prisma.userCreditGrant.updateMany({
    data: { status: "expired" },
    where: {
      expiresAt: { lte: now },
      remainingAmountMicros: { gt: zeroCreditMicros },
      status: "active",
      unit: visionCallGrantUnit,
      userId,
    },
  });
}

// Total Vision API calls left across a user's active, unexpired grants.
export async function visionCallGrantRemaining(userId: string): Promise<bigint> {
  const now = new Date();
  await expireVisionCallGrants(userId, now);
  const aggregate = await prisma.userCreditGrant.aggregate({
    _sum: { remainingAmountMicros: true },
    where: activeVisionGrantWhere(userId, now),
  });

  return aggregate._sum.remainingAmountMicros ?? zeroCreditMicros;
}

// Atomically consume one call from the user's grants, oldest-expiring first.
// Mirrors the subscription quota reservation: a conditional decrement keyed to a
// specific grant row, so concurrent calls can't double-spend, retried against
// the next grant if a race empties the chosen one. Returns the debited grant id
// so a failed request can hand the call back.
export async function reserveVisionCallGrant(
  userId: string,
): Promise<{ ok: true; grantId: string; remaining: bigint } | { ok: false }> {
  const now = new Date();
  await expireVisionCallGrants(userId, now);

  for (let attempt = 0; attempt < maxReserveAttempts; attempt += 1) {
    const grant = await prisma.userCreditGrant.findFirst({
      orderBy: [
        { expiresAt: { sort: "asc", nulls: "last" } },
        { createdAt: "asc" },
      ],
      where: activeVisionGrantWhere(userId, now),
    });
    if (!grant) {
      return { ok: false };
    }

    const debited = await prisma.userCreditGrant.updateMany({
      data: { remainingAmountMicros: { decrement: oneCall } },
      where: {
        id: grant.id,
        remainingAmountMicros: { gt: zeroCreditMicros },
        status: "active",
      },
    });
    if (debited.count === 0) {
      // Another request emptied this grant first; try the next candidate.
      continue;
    }

    // Drop the grant out of future selection once it reaches zero.
    await prisma.userCreditGrant.updateMany({
      data: { status: "exhausted" },
      where: { id: grant.id, remainingAmountMicros: { lte: zeroCreditMicros } },
    });

    return { grantId: grant.id, ok: true, remaining: await visionCallGrantRemaining(userId) };
  }

  return { ok: false };
}

// Hand a reserved call back to its grant when the request ultimately fails, so a
// failed parse doesn't burn the allotment. Re-activates a grant the reservation
// had just exhausted (but never resurrects an expired one).
export async function releaseVisionCallGrant(grantId: string) {
  await prisma.userCreditGrant.updateMany({
    data: { remainingAmountMicros: { increment: oneCall }, status: "active" },
    where: { id: grantId, status: { not: "expired" } },
  });
}
