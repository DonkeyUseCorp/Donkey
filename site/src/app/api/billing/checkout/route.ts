import { NextResponse } from "next/server";

import { auth } from "@/lib/auth";
import { proPriceId } from "@/lib/billing/pro-subscription";
import {
  ensureStripeCustomer,
  getStripe,
  visionPriceId,
} from "@/lib/billing/stripe";
import {
  notFoundResponse,
  unauthorizedResponse,
  withDonkeyAuth,
} from "@/lib/donkey-api-auth";

export const dynamic = "force-dynamic";

// Resolve the Stripe price for a self-serve subscription plan, or null if the
// plan is unknown or not configured. Pro and Vision are separate products.
function subscriptionPriceId(planKey: string): string | null {
  if (planKey === "vision") {
    return visionPriceId();
  }
  if (planKey === "pro") {
    return proPriceId() ?? null;
  }
  return null;
}

// Start a Stripe Checkout session for a subscription (Vision API or Pro).
// Session-only (API keys are not accepted here, the default for withDonkeyAuth).
// This route keeps its getSession call because it needs the user's email/name.
export const POST = withDonkeyAuth(async (request) => {
  const session = await auth.api.getSession({ headers: request.headers });
  if (!session) {
    return unauthorizedResponse();
  }

  const body = (await request.json().catch(() => ({}))) as {
    planKey?: unknown;
  };
  const planKey =
    typeof body.planKey === "string" ? body.planKey : "vision";
  // An unknown or not-yet-configured plan stays a 404 (not 401) so the landing
  // card does not treat it as a sign-in prompt.
  const priceId = subscriptionPriceId(planKey);
  if (!priceId) {
    return notFoundResponse();
  }

  const customerId = await ensureStripeCustomer({
    email: session.user.email,
    name: session.user.name,
    userId: session.user.id,
  });
  const stripe = getStripe();
  const origin = request.nextUrl.origin;
  const checkout = await stripe.checkout.sessions.create({
    allow_promotion_codes: true,
    cancel_url: `${origin}/app/settings?checkout=cancelled`,
    client_reference_id: session.user.id,
    customer: customerId,
    line_items: [{ price: priceId, quantity: 1 }],
    mode: "subscription",
    subscription_data: { metadata: { userId: session.user.id } },
    success_url: `${origin}/app/settings?checkout=success`,
  });

  if (!checkout.url) {
    return NextResponse.json(
      { error: "server-error", message: "Stripe did not return a URL." },
      { status: 502 },
    );
  }

  return NextResponse.json({ url: checkout.url });
});
