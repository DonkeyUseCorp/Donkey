import type Stripe from "stripe";

import { stripeId } from "@/lib/billing/stripe";
import { creditStringToMicros } from "@/lib/credits/amounts";
import { creditAutoReloadKind, creditTopUpKind } from "@/lib/credits/top-up";
import { grantCredits } from "@/lib/credits/inference";
import { prisma } from "@/lib/prisma";

function parseAmountDollars(value: string | undefined): number | null {
  if (!value) {
    return null;
  }
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : null;
}

// Grant purchased credits. Idempotent on (source, sourceId): Stripe can deliver
// the same event more than once, and grantCredits dedupes by sourceId, so the
// Stripe payment_intent id is used as the sourceId.
//
// Purchased credits NEVER expire: no expiresAt / periodEnd is set. That is also
// what places them last in the debit queue (see compareGrantConsumptionOrder in
// credits/inference.ts) — a subscription's periodic allotment is drawn down
// first, and prepaid purchased credit is only spent once that runs out.
async function grantPurchasedCredits(input: {
  userId: string;
  amountDollars: number;
  source: string;
  sourceId: string;
  description: string;
}) {
  await grantCredits({
    amountMicros: creditStringToMicros(String(input.amountDollars)),
    description: input.description,
    // No expiresAt / periodEnd — purchased credits are permanent.
    metadata: {
      amountDollars: String(input.amountDollars),
      purchaseSource: input.source,
    },
    source: input.source,
    sourceId: input.sourceId,
    userId: input.userId,
  });
}

// A one-time top-up Checkout completed. Grant the credits and remember the saved
// payment method so auto-reload can charge it off-session later. The card is
// saved via setup_future_usage on the Checkout session.
export async function handleCreditTopUpCheckout(
  stripe: Stripe,
  session: Stripe.Checkout.Session,
): Promise<void> {
  if (session.mode !== "payment" || session.metadata?.kind !== creditTopUpKind) {
    return;
  }

  const userId = session.metadata?.userId;
  const amountDollars = parseAmountDollars(session.metadata?.amountDollars);
  const paymentIntentId = stripeId(session.payment_intent);
  if (!userId || !amountDollars || !paymentIntentId) {
    console.error("[billing] incomplete credit top-up checkout", {
      amountDollars,
      paymentIntentId,
      session: session.id,
      userId,
    });
    return;
  }

  await grantPurchasedCredits({
    amountDollars,
    description: `$${amountDollars} credit top-up`,
    source: "stripe_topup",
    sourceId: paymentIntentId,
    userId,
  });

  // Saving the card for auto-reload is best-effort: it must never fail the
  // webhook (and thus the already-granted top-up) if it errors.
  try {
    await rememberSavedPaymentMethod(stripe, {
      customerId: stripeId(session.customer),
      paymentIntentId,
      userId,
    });
  } catch (error) {
    console.error("[billing] failed to save auto-reload payment method", error);
  }
}

// A one-time top-up PaymentIntent succeeded. A fallback to the
// checkout.session.completed grant: the two share a (source, sourceId) so
// grantCredits dedupes, but this guarantees the credits land even if the
// Checkout event is dropped or the endpoint isn't subscribed to it.
export async function handleCreditTopUpPaymentSucceeded(
  paymentIntent: Stripe.PaymentIntent,
): Promise<void> {
  if (paymentIntent.metadata?.kind !== creditTopUpKind) {
    return;
  }
  const userId = paymentIntent.metadata?.userId;
  const amountDollars = parseAmountDollars(paymentIntent.metadata?.amountDollars);
  if (!userId || !amountDollars) {
    return;
  }

  await grantPurchasedCredits({
    amountDollars,
    description: `$${amountDollars} credit top-up`,
    source: "stripe_topup",
    sourceId: paymentIntent.id,
    userId,
  });
}

// An off-session auto-reload charge succeeded. Grant the credits and release the
// lock — but only if this PaymentIntent still owns it, so a stale webhook can't
// clear a newer charge's lock.
export async function handleAutoReloadPaymentSucceeded(
  paymentIntent: Stripe.PaymentIntent,
): Promise<void> {
  if (paymentIntent.metadata?.kind !== creditAutoReloadKind) {
    return;
  }
  const userId = paymentIntent.metadata?.userId;
  const amountDollars = parseAmountDollars(paymentIntent.metadata?.amountDollars);
  if (!userId || !amountDollars) {
    return;
  }

  await grantPurchasedCredits({
    amountDollars,
    description: `$${amountDollars} auto-reload`,
    source: "stripe_autoreload",
    sourceId: paymentIntent.id,
    userId,
  });

  await prisma.creditAutoReload.updateMany({
    data: {
      chargingPaymentIntentId: null,
      lastChargeAt: new Date(),
      lastError: null,
      status: "idle",
    },
    where: { chargingPaymentIntentId: paymentIntent.id, userId },
  });
}

// An off-session auto-reload charge failed (e.g. card declined). Record it and
// release the lock it owns; the UI surfaces lastError so the user can fix the card.
export async function handleAutoReloadPaymentFailed(
  paymentIntent: Stripe.PaymentIntent,
): Promise<void> {
  if (paymentIntent.metadata?.kind !== creditAutoReloadKind) {
    return;
  }
  const userId = paymentIntent.metadata?.userId;
  if (!userId) {
    return;
  }

  await prisma.creditAutoReload.updateMany({
    data: {
      chargingPaymentIntentId: null,
      lastError:
        paymentIntent.last_payment_error?.message ?? "The auto-reload charge failed.",
      status: "failed",
    },
    where: { chargingPaymentIntentId: paymentIntent.id, userId },
  });
}

async function rememberSavedPaymentMethod(
  stripe: Stripe,
  input: { userId: string; paymentIntentId: string; customerId: string | null },
): Promise<void> {
  const paymentIntent = await stripe.paymentIntents.retrieve(input.paymentIntentId);
  const paymentMethodId = stripeId(paymentIntent.payment_method);
  if (!paymentMethodId) {
    return;
  }

  await prisma.creditAutoReload.upsert({
    create: {
      stripeCustomerId: input.customerId,
      stripePaymentMethodId: paymentMethodId,
      userId: input.userId,
    },
    update: {
      ...(input.customerId ? { stripeCustomerId: input.customerId } : {}),
      stripePaymentMethodId: paymentMethodId,
    },
    where: { userId: input.userId },
  });
}
