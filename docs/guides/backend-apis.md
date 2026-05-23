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
- Do not run database migrations as part of normal API work.

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
