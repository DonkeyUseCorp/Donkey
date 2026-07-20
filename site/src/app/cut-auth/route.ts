import { NextRequest, NextResponse } from "next/server";

import { DONKEYCUT_CANONICAL } from "@/cut/lib/hosts";
import { auth } from "@/lib/auth";

export const dynamic = "force-dynamic";

/**
 * GET /cut-auth?next=/app/…
 *
 * Apex half of the donkeycut.com sign-in handoff. The session cookie is scoped
 * to donkeyuse.com and Google's redirect_uri is pinned to the apex, so
 * donkeycut.com cannot sign in on its own. It sends the browser here instead:
 * with an apex session (established through the normal /sign-in flow when
 * needed) this mints a short-lived one-time token — the same machinery the Mac
 * app uses — and bounces to donkeycut.com/auth/callback, which exchanges the
 * token for a host-only session cookie there.
 *
 * On donkeycut.com this path rewrites into /cut and 404s, keeping the handoff
 * start apex-only.
 */
export async function GET(request: NextRequest) {
  const rawNext = request.nextUrl.searchParams.get("next") ?? "";
  const next = rawNext.startsWith("/") && !rawNext.startsWith("//") ? rawNext : "/app";

  const session = await auth.api.getSession({ headers: request.headers });
  if (!session) {
    const retry = `/cut-auth?next=${encodeURIComponent(next)}`;
    return NextResponse.redirect(
      new URL(`/sign-in?callbackURL=${encodeURIComponent(retry)}`, request.nextUrl.origin),
    );
  }

  const token = await auth.api.generateOneTimeToken({ headers: request.headers });
  const url = new URL(`${DONKEYCUT_CANONICAL}/auth/callback`);
  url.searchParams.set("token", token.token);
  url.searchParams.set("next", next);
  return NextResponse.redirect(url, 307);
}
