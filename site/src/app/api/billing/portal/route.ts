import { NextResponse } from "next/server";

import { getStripe, visionPortalConfigurationId } from "@/lib/billing/stripe";
import {
  donkeySessionUserId,
  notFoundResponse,
  unauthorizedResponse,
  withDonkeyAuth,
} from "@/lib/donkey-api-auth";
import { prisma } from "@/lib/prisma";

export const dynamic = "force-dynamic";

// Open the Stripe billing portal for the signed-in customer.
export const POST = withDonkeyAuth(async (request) => {
  const userId = donkeySessionUserId(request);
  if (!userId) {
    return unauthorizedResponse();
  }

  const subscription = await prisma.visionApiSubscription.findUnique({
    where: { userId },
  });
  if (!subscription?.stripeCustomerId) {
    return notFoundResponse();
  }

  const stripe = getStripe();
  const configuration = visionPortalConfigurationId();
  const portal = await stripe.billingPortal.sessions.create({
    customer: subscription.stripeCustomerId,
    return_url: `${request.nextUrl.origin}/app/settings`,
    ...(configuration ? { configuration } : {}),
  });

  return NextResponse.json({ url: portal.url });
});
