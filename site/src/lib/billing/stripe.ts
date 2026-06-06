import Stripe from "stripe";

import { prisma } from "@/lib/prisma";

// The Vision API product is a single self-serve plan. The monthly call quota is
// read from the Stripe price metadata (key "monthlyCallQuota") so it can be
// tuned in the Stripe dashboard without a deploy; this constant is the fallback.
export const visionPlanKey = "vision";
export const defaultVisionMonthlyQuota = 5_000;

let cachedStripe: Stripe | null = null;

export function getStripe(): Stripe {
  if (cachedStripe) {
    return cachedStripe;
  }

  const secretKey = process.env.STRIPE_SECRET_KEY;
  if (!secretKey) {
    throw new StripeNotConfiguredError();
  }

  cachedStripe = new Stripe(secretKey);
  return cachedStripe;
}

export class StripeNotConfiguredError extends Error {
  public constructor() {
    super("Stripe is not configured.");
    this.name = "StripeNotConfiguredError";
  }
}

export function visionPriceId(): string {
  const priceId = process.env.STRIPE_VISION_PRICE_ID;
  if (!priceId) {
    throw new StripeNotConfiguredError();
  }

  return priceId;
}

export function quotaFromPrice(price: Stripe.Price | null | undefined): number {
  const raw = price?.metadata?.monthlyCallQuota;
  if (raw) {
    const parsed = Number.parseInt(raw, 10);
    if (Number.isFinite(parsed) && parsed > 0) {
      return parsed;
    }
  }

  return defaultVisionMonthlyQuota;
}

// Reuse one Stripe customer per user. The id is stored on the user's
// VisionApiSubscription row once known.
export async function ensureStripeCustomer(input: {
  userId: string;
  email: string;
  name?: string | null;
}): Promise<string> {
  const existing = await prisma.visionApiSubscription.findUnique({
    where: { userId: input.userId },
  });
  if (existing?.stripeCustomerId) {
    return existing.stripeCustomerId;
  }

  const stripe = getStripe();
  const customer = await stripe.customers.create({
    email: input.email,
    metadata: { userId: input.userId },
    name: input.name ?? undefined,
  });

  await prisma.visionApiSubscription.upsert({
    create: {
      planKey: visionPlanKey,
      stripeCustomerId: customer.id,
      userId: input.userId,
    },
    update: { stripeCustomerId: customer.id },
    where: { userId: input.userId },
  });

  return customer.id;
}

// Source of truth for a subscription's lifecycle. Called from webhook handlers
// with a fully-expanded Stripe subscription; maps it onto our row.
export async function syncVisionSubscription(
  subscription: Stripe.Subscription,
): Promise<void> {
  const userId = await resolveUserIdForSubscription(subscription);
  const customerId = stripeId(subscription.customer);
  if (!userId || !customerId) {
    console.error("[billing] could not resolve user/customer for subscription", {
      customer: customerId,
      subscription: subscription.id,
      userId,
    });
    return;
  }

  const item = subscription.items.data[0];
  const price = item?.price;
  const periodStart = unixToDate(item?.current_period_start ?? null);
  const periodEnd = unixToDate(item?.current_period_end ?? null);

  // Reset the per-period call counter when the billing period rolls over, so a
  // new period starts the quota fresh.
  const existing = await prisma.visionApiSubscription.findUnique({
    select: { currentPeriodStart: true },
    where: { userId },
  });
  const periodRolledOver =
    periodStart !== null &&
    existing?.currentPeriodStart?.getTime() !== periodStart.getTime();

  await prisma.visionApiSubscription.upsert({
    create: {
      cancelAtPeriodEnd: subscription.cancel_at_period_end,
      currentPeriodEnd: periodEnd,
      currentPeriodStart: periodStart,
      monthlyCallQuota: quotaFromPrice(price),
      planKey: visionPlanKey,
      status: subscription.status,
      stripeCustomerId: customerId,
      stripeSubscriptionId: subscription.id,
      userId,
    },
    update: {
      cancelAtPeriodEnd: subscription.cancel_at_period_end,
      currentPeriodEnd: periodEnd,
      currentPeriodStart: periodStart,
      monthlyCallQuota: quotaFromPrice(price),
      status: subscription.status,
      stripeCustomerId: customerId,
      stripeSubscriptionId: subscription.id,
      ...(periodRolledOver ? { periodCallCount: 0 } : {}),
    },
    where: { userId },
  });
}

async function resolveUserIdForSubscription(
  subscription: Stripe.Subscription,
): Promise<string | null> {
  const metadataUserId = subscription.metadata?.userId;
  if (metadataUserId) {
    return metadataUserId;
  }

  const customerId = stripeId(subscription.customer);
  if (customerId) {
    const row = await prisma.visionApiSubscription.findFirst({
      where: { stripeCustomerId: customerId },
    });
    if (row) {
      return row.userId;
    }
  }

  return null;
}

// Normalize a Stripe field that may be an id string or an expanded object (or
// absent) to its id. Shared by the webhook handlers.
export function stripeId(
  value: string | { id: string } | null | undefined,
): string | null {
  if (!value) {
    return null;
  }

  return typeof value === "string" ? value : value.id;
}

function unixToDate(seconds: number | null | undefined): Date | null {
  if (!seconds) {
    return null;
  }

  return new Date(seconds * 1000);
}
