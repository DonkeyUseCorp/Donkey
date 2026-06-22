import { getStripe } from "@/lib/billing/stripe";
import { creditMicrosPerCent, zeroCreditMicros } from "@/lib/credits/amounts";
import { creditAutoReloadKind } from "@/lib/credits/top-up";
import { prisma } from "@/lib/prisma";

// A "charging" lock older than this is treated as stale and may be re-claimed.
// This self-heals a lock left dangling by a dropped success/failure webhook (or a
// PaymentIntent that ended in requires_action), so auto-reload never wedges.
const chargingStaleMs = 10 * 60 * 1000;
// After a failed charge, wait this long before retrying the saved card, so a
// declined card doesn't fire a fresh charge on every subsequent inference.
const failedRetryMs = 60 * 60 * 1000;

// Fired (best-effort, off the response path) after an inference charge commits.
// If the balance fell below the user's threshold, kick off an off-session Stripe
// charge against the saved card. The credit grant itself lands in the
// payment_intent.succeeded webhook — this only starts the charge. balanceMicros
// is the post-charge balance the caller already computed, so we don't re-read it.
export async function maybeTriggerCreditAutoReload(
  userId: string,
  balanceMicros: bigint,
): Promise<void> {
  const config = await prisma.creditAutoReload.findUnique({ where: { userId } });
  if (
    !config ||
    !config.enabled ||
    !config.stripeCustomerId ||
    !config.stripePaymentMethodId ||
    config.amountMicros <= zeroCreditMicros ||
    balanceMicros > config.thresholdMicros
  ) {
    return;
  }

  const now = Date.now();
  const chargingCutoff = new Date(now - chargingStaleMs);
  const failedCutoff = new Date(now - failedRetryMs);

  // Claim the lock atomically. A fresh "charging" lock blocks (one charge at a
  // time); a stale one is reclaimable (dropped webhook); a "failed" one only
  // after the backoff window. updatedAt is set to now by this write, so it
  // doubles as the lock-claim timestamp the cutoffs above compare against.
  const claimed = await prisma.creditAutoReload.updateMany({
    data: { status: "charging" },
    where: {
      enabled: true,
      stripePaymentMethodId: { not: null },
      userId,
      OR: [
        { status: "idle" },
        { status: "charging", updatedAt: { lt: chargingCutoff } },
        { status: "failed", updatedAt: { lt: failedCutoff } },
      ],
    },
  });
  if (claimed.count === 0) {
    return;
  }

  // amountMicros is whole dollars; charge the exact cents it represents.
  const amountCents = Number(config.amountMicros / creditMicrosPerCent);
  try {
    const stripe = getStripe();
    const paymentIntent = await stripe.paymentIntents.create({
      amount: amountCents,
      confirm: true,
      currency: "usd",
      customer: config.stripeCustomerId,
      metadata: {
        amountDollars: String(amountCents / 100),
        kind: creditAutoReloadKind,
        userId,
      },
      off_session: true,
      payment_method: config.stripePaymentMethodId,
    });
    // Record which PaymentIntent owns the lock so its webhook only releases
    // its own charge (a later charge's lock is never clobbered by a stale one).
    await prisma.creditAutoReload.updateMany({
      data: { chargingPaymentIntentId: paymentIntent.id },
      where: { userId, status: "charging" },
    });
  } catch (error) {
    await prisma.creditAutoReload.updateMany({
      data: {
        chargingPaymentIntentId: null,
        lastError:
          error instanceof Error ? error.message : "Auto-reload charge failed.",
        status: "failed",
      },
      where: { userId },
    });
  }
}
