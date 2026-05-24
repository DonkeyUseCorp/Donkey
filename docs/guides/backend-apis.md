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
shared schemas, stateless provider calls, and Swift contracts must stay provider-neutral;
provider names are configuration/data inside private adapters only.

- Require `x-donkey-client-id` on inference routes.
- Keep remote asset generation state on the Mac side. The backend can create or
  refresh remote provider jobs and return provider job IDs, provider generation
  IDs, polling URLs, and output references, but it must not persist prompts,
  generation records, provider output references, or generated assets in
  Postgres.
- Keep provider-specific request mapping behind the inference provider registry.
  Route handlers should import the registry and neutral schemas, not individual
  adapters.
- Computer-use provider tools are registered as request tools and mapped by
  adapters. Browser interaction uses Gemini through
  `donkey_gemini_browser_interaction`; guarded macOS desktop interaction uses
  OpenAI through `donkey_openai_mac_desktop_interaction`, which the hosted
  Responses adapter maps to OpenAI's `computer` tool.
- The Gemini adapter uses the official `@google/genai` Node/TypeScript SDK for
  general non-streaming chat, normal structured Responses calls, and browser
  computer-use calls. It uses Vertex AI's global endpoint only when
  `GOOGLE_APPLICATION_CREDENTIALS_JSON` includes a `project_id`. If the project
  is missing, the provider is unavailable. The adapter's defaults should track
  Google's newest supported Gemini models: use the latest stable Flash model for
  normal chat and Responses calls, and the latest Google-listed Computer
  Use-capable model for browser Computer Use tool calls. Keep model selection in
  code rather than environment overrides. For Google Cloud credits, set
  `GOOGLE_APPLICATION_CREDENTIALS_JSON` as a hosted-deploy sensitive env var
  rather than storing Google provider credentials in the Mac app.
- The OpenAI hosted Responses adapter uses `OPENAI_API_KEY` only for macOS
  desktop computer-use. Keep that credential in the hosted deployment
  environment; the Mac app must not carry OpenAI provider credentials.

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
