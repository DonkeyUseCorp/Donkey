import { NextResponse } from "next/server";

import { auth } from "@/lib/auth";
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

// Start a Stripe Checkout session for the Vision API subscription. Session-only
// (API keys are not accepted here, the default for withDonkeyAuth). This route
// keeps its getSession call because it needs the user's email/name for Stripe.
export const POST = withDonkeyAuth(async (request) => {
  const session = await auth.api.getSession({ headers: request.headers });
  if (!session) {
    return unauthorizedResponse();
  }

  // Only the Vision API plan is self-serve. Other plan keys (e.g. the Mac app
  // "pro" plan) are not wired to Stripe yet. This stays a 404 rather than a 401
  // so the landing card does not treat it as a sign-in prompt.
  const body = (await request.json().catch(() => ({}))) as {
    planKey?: unknown;
  };
  const planKey =
    typeof body.planKey === "string" ? body.planKey : "vision";
  if (planKey !== "vision") {
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
    cancel_url: `${origin}/dashboard?checkout=cancelled`,
    client_reference_id: session.user.id,
    customer: customerId,
    line_items: [{ price: visionPriceId(), quantity: 1 }],
    mode: "subscription",
    subscription_data: { metadata: { userId: session.user.id } },
    success_url: `${origin}/dashboard?checkout=success`,
  });

  if (!checkout.url) {
    return NextResponse.json(
      { error: "server-error", message: "Stripe did not return a URL." },
      { status: 502 },
    );
  }

  return NextResponse.json({ url: checkout.url });
});
