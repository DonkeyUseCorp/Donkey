import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";

import { auth } from "@/lib/auth";

export const dynamic = "force-dynamic";

const callbackSearchParamsSchema = z.object({
  error: z.string().optional(),
  state: z.string().min(1),
});

/**
 * GET /mac-auth/callback
 *
 * Browser landing point after Better Auth completes Google OAuth for the Mac app.
 * It mints a short-lived one-time token from the browser session, then deep-links
 * that code back to the native app for cookie-jar exchange.
 */
export async function GET(request: NextRequest) {
  const parsedParams = callbackSearchParamsSchema.safeParse(
    Object.fromEntries(request.nextUrl.searchParams),
  );
  if (!parsedParams.success) {
    return NextResponse.json(
      {
        error: "Invalid callback",
        message: "Missing Mac app state token.",
      },
      { status: 400 },
    );
  }

  const { error, state } = parsedParams.data;
  if (error) {
    return redirectToMac(macCallbackURL(state, { error }));
  }

  try {
    const token = await auth.api.generateOneTimeToken({
      headers: request.headers,
    });

    return redirectToMac(macCallbackURL(state, { code: token.token }));
  } catch {
    return redirectToMac(macCallbackURL(state, { error: "session" }));
  }
}

function redirectToMac(url: URL) {
  return new NextResponse(null, {
    status: 302,
    headers: {
      Location: url.toString(),
    },
  });
}

function macCallbackURL(
  state: string,
  query: {
    code?: string;
    error?: string;
  },
) {
  const callbackScheme = process.env.DONKEY_MAC_AUTH_CALLBACK_SCHEME ?? "donkey";
  const url = new URL(`${callbackScheme}://auth/callback`);
  url.searchParams.set("state", state);

  if (query.code) {
    url.searchParams.set("code", query.code);
  }

  if (query.error) {
    url.searchParams.set("error", query.error);
  }

  return url;
}
