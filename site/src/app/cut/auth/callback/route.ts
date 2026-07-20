import { NextRequest, NextResponse } from "next/server";

import { auth } from "@/lib/auth";
import { stripCookieDomain } from "@/lib/cut-auth";

export const dynamic = "force-dynamic";

/**
 * GET donkeycut.com/auth/callback?token=…&next=…  (route path /cut/auth/callback)
 *
 * donkeycut.com half of the sign-in handoff (see /cut-auth). Verifies the
 * one-time token minted on the apex; the verify response carries the session
 * Set-Cookie (the Mac app's cookie exchanger rides the same endpoint), which is
 * re-scoped to a host-only donkeycut.com cookie. A missing or expired token
 * just lands the user on `next` signed out.
 */
export async function GET(request: NextRequest) {
  const params = request.nextUrl.searchParams;
  const rawNext = params.get("next") ?? "";
  const next = rawNext.startsWith("/") && !rawNext.startsWith("//") ? rawNext : "/app";
  const token = params.get("token");

  const origin = `${request.nextUrl.protocol}//${request.headers.get("host") ?? "donkeycut.com"}`;
  const res = NextResponse.redirect(new URL(next, origin), 303);
  if (!token) return res;

  try {
    const verified = await auth.api.verifyOneTimeToken({
      body: { token },
      asResponse: true,
    });
    for (const cookie of verified.headers.getSetCookie()) {
      res.headers.append("set-cookie", stripCookieDomain(cookie));
    }
  } catch {
    // Expired or replayed token: arrive signed out and let the page's own
    // sign-in entry points restart the handoff.
  }
  return res;
}
