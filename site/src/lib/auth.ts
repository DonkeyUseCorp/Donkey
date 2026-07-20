import { apiKey } from "@better-auth/api-key";
import { betterAuth } from "better-auth";
import { prismaAdapter } from "better-auth/adapters/prisma";
import { oneTimeToken } from "better-auth/plugins";

import { DONKEYCUT_CANONICAL } from "@/cut/lib/hosts";
import { macAuthRedirectOrigins } from "@/lib/mac-auth";
import { provisionSignupGrants } from "@/lib/onboarding/signup-grants";
import { prisma } from "@/lib/prisma";

// Prefix for issued Vision API keys. The full secret is shown to the developer
// once at creation; only a hash is stored (handled by the apiKey plugin).
export const visionApiKeyPrefix = "dk_live_";

// Both donkeyuse.com and www.donkeyuse.com serve the app, but the Google OAuth
// redirect_uri is pinned to BETTER_AUTH_URL's host. A sign-in started on one
// host would set a host-only state cookie there while the callback lands on the
// other, so better-auth can't find the cookie and rejects it as state_mismatch.
// Scoping the auth cookies to the registrable host lets them ride across both,
// and across the cut.donkeyuse.com subdomain that serves the editor.
//
// Local dev needs none of this: Cut is served from the apex under /cut, so its
// session cookie is already same-origin. (A Domain=localhost cookie doesn't
// reach a cut.localhost subdomain in Chrome anyway.)
function crossSubDomainCookieDomain() {
  const baseURL = process.env.BETTER_AUTH_URL;
  if (!baseURL) return undefined;

  let host: string;
  try {
    host = new URL(baseURL).hostname;
  } catch {
    return undefined;
  }

  if (/^[0-9.]+$/.test(host)) return undefined;
  if (host === "localhost" || host.endsWith(".localhost")) return undefined;

  return host;
}

// In production the editor is served from cut.donkeyuse.com, a different origin
// from the apex where Google's redirect_uri is pinned, so a sign-in that starts
// on Cut redirects back to that origin — it has to be trusted for the redirect
// to be honored. Local dev serves Cut under /cut on the apex (same origin), so
// nothing extra is needed there.
function cutRedirectOrigins(): string[] {
  const baseURL = process.env.BETTER_AUTH_URL;
  if (!baseURL) return [];
  try {
    const url = new URL(baseURL);
    if (url.hostname === "localhost" || url.hostname.endsWith(".localhost")) return [];
    if (!url.hostname.startsWith("cut.")) url.hostname = `cut.${url.hostname}`;
    return [url.origin];
  } catch {
    return [];
  }
}

const cookieDomain = crossSubDomainCookieDomain();

export const auth = betterAuth({
  baseURL: process.env.BETTER_AUTH_URL,
  secret: process.env.BETTER_AUTH_SECRET,
  // donkeycut.com POSTs to the auth API cross-origin (sign-out, session
  // refresh), so better-auth's Origin check must trust it alongside the
  // cut.donkeyuse.com sign-in redirects.
  trustedOrigins: [...macAuthRedirectOrigins(), ...cutRedirectOrigins(), DONKEYCUT_CANONICAL],
  // Sessions last a year, and the rolling expiry is refreshed daily on use, so an active user effectively
  // never has to sign in again. The Mac app's native session cookie rides this same lifetime, keeping the
  // desktop signed in long after the handoff.
  session: {
    expiresIn: 60 * 60 * 24 * 365,
    updateAge: 60 * 60 * 24,
  },
  advanced: cookieDomain
    ? { crossSubDomainCookies: { enabled: true, domain: cookieDomain } }
    : undefined,
  database: prismaAdapter(prisma, {
    provider: "postgresql",
  }),
  databaseHooks: {
    user: {
      create: {
        // Every new account is provisioned with its signup grants (app credits
        // + free Vision API calls). provisionSignupGrants is idempotent and
        // swallows its own errors, so it never blocks user creation.
        after: async (user) => {
          await provisionSignupGrants(user.id);
        },
      },
    },
  },
  emailAndPassword: {
    enabled: false,
  },
  socialProviders: {
    google: {
      clientId: process.env.GOOGLE_CLIENT_ID ?? "",
      clientSecret: process.env.GOOGLE_CLIENT_SECRET ?? "",
    },
  },
  plugins: [
    oneTimeToken({
      expiresIn: 60,
      storeToken: "hashed",
    }),
    apiKey({
      // We enforce our own monthly call quota and per-key rate limit on the
      // vision route, so the plugin's built-in rate limiting stays off.
      defaultPrefix: visionApiKeyPrefix,
      enableMetadata: true,
      rateLimit: {
        enabled: false,
      },
    }),
  ],
});
