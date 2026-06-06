import { apiKey } from "@better-auth/api-key";
import { betterAuth } from "better-auth";
import { prismaAdapter } from "better-auth/adapters/prisma";
import { oneTimeToken } from "better-auth/plugins";

import { prisma } from "@/lib/prisma";

// Prefix for issued Vision API keys. The full secret is shown to the developer
// once at creation; only a hash is stored (handled by the apiKey plugin).
export const visionApiKeyPrefix = "dk_live_";

function macAuthRedirectOrigins() {
  const configuredOrigins = process.env.DONKEY_MAC_AUTH_REDIRECT_ORIGINS
    ?.split(",")
    .map((origin) => origin.trim())
    .filter(Boolean);

  return configuredOrigins && configuredOrigins.length > 0
    ? configuredOrigins
    : ["donkey://"];
}

export const auth = betterAuth({
  baseURL: process.env.BETTER_AUTH_URL,
  secret: process.env.BETTER_AUTH_SECRET,
  trustedOrigins: macAuthRedirectOrigins(),
  database: prismaAdapter(prisma, {
    provider: "postgresql",
  }),
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
