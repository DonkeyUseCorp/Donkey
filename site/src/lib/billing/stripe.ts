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

// Optional: a specific billing portal configuration (bpc_...). When unset,
// Stripe uses the account's default portal configuration.
export function visionPortalConfigurationId(): string | undefined {
  return process.env.STRIPE_PORTAL_CONFIGURATION_ID || undefined;
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

// Reuse one Stripe customer per user, stored on User.stripeCustomerId so every
// billing product (Pro, Vision, top-ups) shares it and a customer is never
// duplicated — and a Pro-only or credit-only user gets no phantom Vision row.
export async function ensureStripeCustomer(input: {
  userId: string;
  email: string;
  name?: string | null;
}): Promise<string> {
  const user = await prisma.user.findUnique({
    select: { stripeCustomerId: true },
    where: { id: input.userId },
  });
  if (user?.stripeCustomerId) {
    return user.stripeCustomerId;
  }

  // Legacy rows stored the customer id on the Vision subscription; reuse it (and
  // backfill the user) so an existing Vision customer is never re-created.
  const legacyVision = await prisma.visionApiSubscription.findUnique({
    select: { stripeCustomerId: true },
    where: { userId: input.userId },
  });
  if (legacyVision?.stripeCustomerId) {
    await prisma.user.update({
      data: { stripeCustomerId: legacyVision.stripeCustomerId },
      where: { id: input.userId },
    });
    return legacyVision.stripeCustomerId;
  }

  const stripe = getStripe();
  const customer = await stripe.customers.create({
    email: input.email,
    metadata: { userId: input.userId },
    name: input.name ?? undefined,
  });
  await prisma.user.update({
    data: { stripeCustomerId: customer.id },
    where: { id: input.userId },
  });
  return customer.id;
}

// Resolve which user a Stripe subscription belongs to: the userId stamped into
// subscription metadata at checkout, falling back to the per-user Stripe customer
// id. Shared by the Vision and Pro sync paths so they can't resolve differently.
export async function resolveSubscriptionUserId(
  subscription: Stripe.Subscription,
): Promise<string | null> {
  const metadataUserId = subscription.metadata?.userId;
  if (metadataUserId) {
    return metadataUserId;
  }
  const customerId = stripeId(subscription.customer);
  if (customerId) {
    const user = await prisma.user.findUnique({
      select: { id: true },
      where: { stripeCustomerId: customerId },
    });
    if (user) {
      return user.id;
    }
  }
  return null;
}

// Source of truth for a subscription's lifecycle. Called from webhook handlers
// with a fully-expanded Stripe subscription; maps it onto our row.
export async function syncVisionSubscription(
  subscription: Stripe.Subscription,
): Promise<void> {
  const userId = await resolveSubscriptionUserId(subscription);
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

// Epoch seconds (Stripe's unit) to Date, or null when absent. Shared by the
// Vision and Pro subscription sync paths.
export function unixToDate(seconds: number | null | undefined): Date | null {
  if (!seconds) {
    return null;
  }

  return new Date(seconds * 1000);
}
