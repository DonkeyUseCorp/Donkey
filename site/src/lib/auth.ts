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

// Both donkeycut.com and www.donkeycut.com serve the site, but the Google OAuth
// redirect_uri is pinned to BETTER_AUTH_URL's host. A sign-in started on one
// host would set a host-only state cookie there while the callback lands on the
// other, so better-auth can't find the cookie and rejects it as state_mismatch.
// Scoping the auth cookies to the registrable host lets them ride across both.
//
// Local dev needs none of this: everything is served from the one localhost
// origin, so the session cookie is already same-origin. (A Domain=localhost
// cookie doesn't reach a subdomain in Chrome anyway.)
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

const cookieDomain = crossSubDomainCookieDomain();

export const auth = betterAuth({
  baseURL: process.env.BETTER_AUTH_URL,
  secret: process.env.BETTER_AUTH_SECRET,
  // donkeycut.com is the canonical host and its www. mirror POSTs to the auth
  // API cross-origin (sign-out, session refresh), so better-auth's Origin check
  // trusts it alongside the Mac-app handoff scheme.
  trustedOrigins: [...macAuthRedirectOrigins(), DONKEYCUT_CANONICAL],
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
