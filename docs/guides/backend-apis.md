# Backend API Guide

Backend APIs live in `site/src/app/api/**/route.ts`.

## Rules

- APIs are authenticated by default.
- Always wrap route handlers with `withDonkeyAuth` from `@/lib/donkey-api-auth`.
- Treat public endpoints as exceptions that need an explicit product reason.
- Better Auth is mounted as the public auth exception at `site/src/app/api/auth/[...all]/route.ts`; configure it through `@/lib/auth`.
- The supported interactive login provider is Google OAuth only. Keep `emailAndPassword.enabled` false unless the product explicitly adds another login method.
- Configure Google OAuth with `${BETTER_AUTH_URL}/api/auth/callback/google` as the redirect URI.
- Keep the Mac app callback origin (`donkey://` by default) in Better Auth
  trusted origins so `/mac-auth` can return successful Google sign-in to the
  app.
- Mac app sign-in uses Better Auth's one-time-token plugin. `/mac-auth/callback`
  mints a short-lived code from the browser session, then the app exchanges it
  at `/api/auth/one-time-token/verify` so `URLSession` stores the resulting
  Better Auth cookie in the app-owned cookie jar.
- In Vercel, configure `BETTER_AUTH_URL`, `BETTER_AUTH_SECRET`,
  `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, and
  `DONKEY_MAC_AUTH_REDIRECT_ORIGINS`. Do not commit real OAuth credentials.
- Validate request bodies, search params, and route params with Zod before using them.
- Verify resource ownership before reading or mutating scoped data.
- Return explicit `NextResponse.json(...)` responses with the intended status code.
- Keep Prisma access server-only through `@/lib/prisma`.
- Keep Prisma table/model definitions in logically grouped sibling `.prisma`
  files under `site/prisma/`. Never put table/model definitions in
  `site/prisma/schema.prisma`; reserve that file for shared Prisma
  configuration such as generator and datasource blocks.
- Do not run database migrations as part of normal API work.

## Inference Gateway

The inference gateway lives under `site/src/app/api/inference/**`. It is a
Mac-app-facing backend boundary for remote model and asset generation. Routes,
shared schemas, Prisma records, and Swift contracts must stay provider-neutral;
provider names are configuration/data inside private adapters only.

- Require `x-donkey-client-id` on inference routes and use it as the ownership
  boundary for generation records.
- Store generation metadata and provider output references in
  `InferenceGeneration`; do not store generated binary files in Postgres.
- Return or proxy downloadable outputs through authenticated Donkey API routes so
  the Mac app can save files into the user's Downloads folder without provider
  credentials.
- Keep provider-specific request mapping behind the inference provider registry.
  Route handlers should import the registry and neutral schemas, not individual
  adapters.

## Pattern

```typescript
import { NextResponse } from "next/server";

import { withDonkeyAuth } from "@/lib/donkey-api-auth";

export const GET = withDonkeyAuth((request) => {
  return NextResponse.json({
    clientId: request.donkey.clientId,
  });
});
```
