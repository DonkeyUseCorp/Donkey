import { apiKey } from "@better-auth/api-key";
import { betterAuth } from "better-auth";
import { prismaAdapter } from "better-auth/adapters/prisma";
import { oneTimeToken } from "better-auth/plugins";

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
// Scoping the auth cookies to the registrable host lets them ride across both.
// Returns undefined for hosts that can't carry a Domain attribute (localhost,
// bare IPs), so local development keeps working.
function crossSubDomainCookieDomain() {
  const baseURL = process.env.BETTER_AUTH_URL;
  if (!baseURL) return undefined;

  let host: string;
  try {
    host = new URL(baseURL).hostname;
  } catch {
    return undefined;
  }

  if (host === "localhost" || host.endsWith(".localhost") || /^[0-9.]+$/.test(host)) {
    return undefined;
  }

  return host;
}

const cookieDomain = crossSubDomainCookieDomain();

export const auth = betterAuth({
  baseURL: process.env.BETTER_AUTH_URL,
  secret: process.env.BETTER_AUTH_SECRET,
  trustedOrigins: macAuthRedirectOrigins(),
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
