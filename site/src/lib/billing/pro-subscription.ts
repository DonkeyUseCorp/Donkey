import type Stripe from "stripe";

import { stripeId } from "@/lib/billing/stripe";
import { zeroCreditMicros } from "@/lib/credits/amounts";
import { grantCredits } from "@/lib/credits/inference";
import { prisma } from "@/lib/prisma";

// Credit micros per Stripe cent. $1 = 100 cents = 1,000,000 micros, so 1 cent = 10,000 micros.
const creditMicrosPerCent = BigInt(10_000);

// Donkey Pro: the Mac app subscription, separate from the Vision API product.
export const proPlanKey = "pro";

// Stripe subscription statuses that include the Pro allowance.
const activeStatuses = new Set(["active", "trialing"]);

export function isActiveProStatus(status: string): boolean {
  return activeStatuses.has(status);
}

export function proPriceId(): string | undefined {
  return process.env.STRIPE_PRO_PRICE_ID || undefined;
}

// The included monthly inference allowance equals the Pro plan price: a $20/mo
// plan includes $20 of app inference each period. Read straight from the
// recurring price's unit_amount (cents) — no separate metadata to configure.
export function allowanceMicrosFromPrice(
  price: Stripe.Price | null | undefined,
): bigint {
  const cents = price?.unit_amount;
  if (typeof cents === "number" && Number.isFinite(cents) && cents > 0) {
    return BigInt(Math.round(cents)) * creditMicrosPerCent;
  }
  return zeroCreditMicros;
}

export async function getActiveProSubscription(userId: string) {
  const subscription = await prisma.proSubscription.findUnique({
    where: { userId },
  });
  if (!subscription || !isActiveProStatus(subscription.status)) {
    return null;
  }
  return subscription;
}

// True when a Stripe subscription belongs to the Pro product (vs Vision). Used
// to route shared subscription webhook events to the right sync.
export function subscriptionIsPro(subscription: Stripe.Subscription): boolean {
  const priceId = subscription.items.data[0]?.price?.id;
  return Boolean(priceId && proPriceId() && priceId === proPriceId());
}

// Source of truth for a Pro subscription's lifecycle. Maps the Stripe object
// onto our row and, for each active billing period, grants the included
// allowance into the credit balance as an expiring grant. The grant is
// idempotent per (subscription, period start), so repeated webhook deliveries
// and the create/update/invoice events for one period grant the allowance once.
export async function syncProSubscription(
  subscription: Stripe.Subscription,
): Promise<void> {
  const userId = await resolveUserIdForSubscription(subscription);
  const customerId = stripeId(subscription.customer);
  if (!userId) {
    console.error("[billing] could not resolve user for Pro subscription", {
      customer: customerId,
      subscription: subscription.id,
    });
    return;
  }

  const item = subscription.items.data[0];
  const price = item?.price;
  const periodStart = unixToDate(item?.current_period_start ?? null);
  const periodEnd = unixToDate(item?.current_period_end ?? null);
  const allowanceMicros = allowanceMicrosFromPrice(price);

  await prisma.proSubscription.upsert({
    create: {
      cancelAtPeriodEnd: subscription.cancel_at_period_end,
      currentPeriodEnd: periodEnd,
      currentPeriodStart: periodStart,
      monthlyAllowanceMicros: allowanceMicros,
      planKey: proPlanKey,
      status: subscription.status,
      stripeCustomerId: customerId,
      stripeSubscriptionId: subscription.id,
      userId,
    },
    update: {
      cancelAtPeriodEnd: subscription.cancel_at_period_end,
      currentPeriodEnd: periodEnd,
      currentPeriodStart: periodStart,
      monthlyAllowanceMicros: allowanceMicros,
      status: subscription.status,
      stripeCustomerId: customerId,
      stripeSubscriptionId: subscription.id,
    },
    where: { userId },
  });

  // Grant the period's included allowance once it is active and the period is
  // known. expiresAt = period end means it is spent before never-expiring
  // purchased credits (see compareGrantConsumptionOrder) and does not roll over.
  if (
    isActiveProStatus(subscription.status) &&
    periodStart &&
    periodEnd &&
    allowanceMicros > BigInt(0)
  ) {
    await grantCredits({
      amountMicros: allowanceMicros,
      description: "Donkey Pro monthly allowance",
      expiresAt: periodEnd,
      metadata: { plan: proPlanKey },
      periodEnd,
      periodStart,
      source: "pro_subscription",
      sourceId: `pro:${subscription.id}:${item?.current_period_start ?? 0}`,
      userId,
    });
  }
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
    const row = await prisma.proSubscription.findFirst({
      where: { stripeCustomerId: customerId },
    });
    if (row) {
      return row.userId;
    }
  }

  return null;
}

function unixToDate(seconds: number | null | undefined): Date | null {
  if (!seconds) {
    return null;
  }
  return new Date(seconds * 1000);
}
