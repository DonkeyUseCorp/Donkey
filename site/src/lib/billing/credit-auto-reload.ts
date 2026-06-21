import {
  creditAutoReloadKind,
  dollarsToStripeCents,
} from "@/lib/billing/credit-purchases";
import { getStripe } from "@/lib/billing/stripe";
import { creditMicrosPerCredit, zeroCreditMicros } from "@/lib/credits/amounts";
import { prisma } from "@/lib/prisma";

// Fired after an inference charge commits (best-effort, non-blocking). If the
// balance fell below the user's auto-reload threshold, start an off-session
// Stripe charge against the saved card. The actual credit grant happens in the
// payment_intent.succeeded webhook, not here — this only kicks off the charge.
export async function maybeTriggerCreditAutoReload(userId: string): Promise<void> {
  const config = await prisma.creditAutoReload.findUnique({ where: { userId } });
  if (
    !config ||
    !config.enabled ||
    !config.stripeCustomerId ||
    !config.stripePaymentMethodId ||
    config.status === "charging" ||
    config.amountMicros <= zeroCreditMicros
  ) {
    return;
  }

  const account = await prisma.userCreditAccount.findUnique({
    select: { balanceMicros: true },
    where: { userId },
  });
  if (!account || account.balanceMicros > config.thresholdMicros) {
    return;
  }

  // Claim the charging lock atomically. If another concurrent run already
  // claimed it, count is 0 and we bail — never double-charge.
  const claimed = await prisma.creditAutoReload.updateMany({
    data: { status: "charging" },
    where: { status: { not: "charging" }, userId },
  });
  if (claimed.count === 0) {
    return;
  }

  const amountDollars = Number(config.amountMicros / creditMicrosPerCredit);
  try {
    const stripe = getStripe();
    await stripe.paymentIntents.create({
      amount: dollarsToStripeCents(amountDollars),
      confirm: true,
      currency: "usd",
      customer: config.stripeCustomerId,
      metadata: {
        amountDollars: String(amountDollars),
        kind: creditAutoReloadKind,
        userId,
      },
      off_session: true,
      payment_method: config.stripePaymentMethodId,
    });
  } catch (error) {
    await prisma.creditAutoReload.updateMany({
      data: {
        lastError:
          error instanceof Error ? error.message : "Auto-reload charge failed.",
        status: "failed",
      },
      where: { userId },
    });
  }
}
