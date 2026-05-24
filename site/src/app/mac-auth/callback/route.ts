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
 * It mints a short-lived one-time token from the browser session, then renders
 * a small handoff page that deep-links that code back to the native app for
 * cookie-jar exchange.
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
    return macHandoffPage(macCallbackURL(state, { error }), {
      heading: "Returning to Donkey",
      message: "Google sign-in did not finish. Donkey will ask you to try again.",
    });
  }

  try {
    const token = await auth.api.generateOneTimeToken({
      headers: request.headers,
    });

    return macHandoffPage(macCallbackURL(state, { code: token.token }), {
      heading: "You're signed in",
      message: "Donkey is opening on your Mac. You can close this tab after the app appears.",
    });
  } catch {
    return macHandoffPage(macCallbackURL(state, { error: "session" }), {
      heading: "Returning to Donkey",
      message: "Donkey could not create a Mac session yet. The app will ask you to try again.",
    });
  }
}

function macHandoffPage(
  url: URL,
  copy: {
    heading: string;
    message: string;
  },
) {
  const callbackURL = url.toString();
  const scriptURL = JSON.stringify(callbackURL)
    .replace(/</g, "\\u003c")
    .replace(/\u2028/g, "\\u2028")
    .replace(/\u2029/g, "\\u2029");

  return new NextResponse(`<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${escapeHTML(copy.heading)} - Donkey</title>
  <style>
    :root {
      color-scheme: dark;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }

    * {
      box-sizing: border-box;
    }

    body {
      align-items: center;
      background: #1f201e;
      color: #f7f4ee;
      display: flex;
      justify-content: center;
      margin: 0;
      min-height: 100vh;
      padding: 24px;
    }

    main {
      align-items: center;
      display: grid;
      gap: 18px;
      justify-items: center;
      max-width: 460px;
      text-align: center;
      width: 100%;
    }

    img {
      border-radius: 18px;
      box-shadow: 0 18px 44px rgba(0, 0, 0, 0.32);
      height: 72px;
      width: 72px;
    }

    h1 {
      font-size: clamp(36px, 7vw, 48px);
      font-weight: 800;
      letter-spacing: 0;
      line-height: 1.04;
      margin: 18px 0 0;
    }

    p {
      color: rgba(247, 244, 238, 0.68);
      font-size: 17px;
      line-height: 1.5;
      margin: 0;
      max-width: 390px;
    }

    a {
      align-items: center;
      border: 1px solid rgba(247, 244, 238, 0.26);
      border-radius: 999px;
      color: #f7f4ee;
      display: inline-flex;
      font-size: 15px;
      font-weight: 750;
      height: 44px;
      justify-content: center;
      margin-top: 12px;
      padding: 0 20px;
      text-decoration: none;
    }

    a:focus-visible {
      outline: 3px solid rgba(115, 162, 255, 0.72);
      outline-offset: 3px;
    }
  </style>
</head>
<body>
  <main>
    <img alt="" src="/donkey-app-icon.png" />
    <h1>${escapeHTML(copy.heading)}</h1>
    <p>${escapeHTML(copy.message)}</p>
    <a href="${escapeHTMLAttribute(callbackURL)}">Open Donkey</a>
  </main>
  <script>
    const callbackURL = ${scriptURL};
    window.setTimeout(() => {
      window.location.href = callbackURL;
    }, 250);
  </script>
</body>
</html>`, {
    status: 200,
    headers: {
      "Cache-Control": "no-store",
      "Content-Type": "text/html; charset=utf-8",
      "Referrer-Policy": "no-referrer",
    },
  });
}

function escapeHTML(value: string) {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function escapeHTMLAttribute(value: string) {
  return escapeHTML(value)
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
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
