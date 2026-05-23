import { betterAuth } from "better-auth";
import { prismaAdapter } from "better-auth/adapters/prisma";
import { oneTimeToken } from "better-auth/plugins";

import { prisma } from "@/lib/prisma";

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
      expiresIn: 3,
      storeToken: "hashed",
    }),
  ],
});
