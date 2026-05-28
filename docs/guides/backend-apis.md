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
  mints a short-lived code from the browser session, renders a browser handoff
  page that opens `donkey://auth/callback`, then the app exchanges the code at
  `/api/auth/one-time-token/verify` so `URLSession` stores the resulting Better
  Auth cookie in the app-owned cookie jar. The code should remain short-lived
  while still allowing a manual "Open Donkey" fallback click.
- In Vercel, configure `BETTER_AUTH_URL`, `BETTER_AUTH_SECRET`,
  `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, and
  `DONKEY_MAC_AUTH_REDIRECT_ORIGINS`. Do not commit real OAuth credentials.
- Validate request bodies, search params, and route params with Zod before using them.
- Verify resource ownership before reading or mutating scoped data.
- Return explicit `NextResponse.json(...)` responses with the intended status code.
- Do not wrap route handlers in `try/catch` unless the handler can recover and
  return a different intentional response. Let unexpected errors surface to the
  framework's logging path.
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
  Responses adapter maps to OpenAI's `computer` tool. Developer-only read-only
  UI inspection uses `donkey_debug_ui_inspection`; adapters route it through
  hosted vision/computer-use-capable models but must not forward or execute UI
  action calls.
- Screenshot parsing is available at `POST /api/inference/screenshots/parse/`.
  It accepts scoped app/window or system-navigation screenshots only, never
  whole-desktop captures, and returns read-only UI evidence in the Mac app's
  local UI understanding shape. The default provider is Gemini 2.5 Flash through
  a dedicated screenshot-parsing module configured with hosted Google
  credentials or `GEMINI_API_KEY`.
- The Gemini adapter uses the official `@google/genai` Node/TypeScript SDK for
  general non-streaming chat, structured Responses calls, and browser
  computer-use calls. It uses Vertex AI's global endpoint only when
  `GOOGLE_APPLICATION_CREDENTIALS_JSON` includes a `project_id`. If the project
  is missing, the provider is unavailable. The adapter's defaults should route
  fast structured task-intent and follow-up decisions to `gemini-3.1-flash-lite`,
  keep `gemini-3.5-flash` available for general chat and non-decision Responses
  calls, and use `gemini-3-flash-preview` for browser Computer Use tool calls.
  Keep model selection in code rather than environment overrides. Structured
  decision requests normalize JSON schemas for Gemini and retry without
  provider-enforced schema when Vertex rejects schema parameters; Mac-side
  runtime validation still owns whether the returned JSON is executable. For
  Google Cloud credits, set
  `GOOGLE_APPLICATION_CREDENTIALS_JSON` as a hosted-deploy sensitive env var
  rather than storing Google provider credentials in the Mac app.
- The OpenAI hosted Responses adapter uses `OPENAI_API_KEY` only for macOS
  desktop computer-use and developer UI inspection. Keep that credential in the
  hosted deployment environment; the Mac app must not carry OpenAI provider
  credentials.

## Hosted Model Credits

Hosted inference usage is metered per authenticated user in the backend. The
Mac app still sends provider-neutral inference requests; the backend owns credit
checks, provider/model rates, debits, and audit rows.

- Keep one visible balance per user, with auditable grants, expirations, usage
  charges, and adjustments behind it.
- Provider-invoking inference routes check credits before calling a hosted
  model, then charge after provider success. Model listing remains uncharged.
  Provider/config/runtime failures after a successful credit preflight are
  recorded as zero-cost failed usage events with sanitized error codes.
- Manual whole-dollar credit grants are available at `POST /api/credits/grants/`.
  The caller must be authenticated and have `user.superUser = true`; the target
  user is addressed by internal `user.id`. The route treats `$1` as `1` hosted
  inference credit (`1,000,000` micros), then writes the grant and ledger entry.
- Known OpenAI, Gemini, and ElevenLabs models use backend-owned provider price
  fallbacks unless an active exact or provider/model database rate overrides
  them. These fallbacks mirror current public provider API prices, apply the
  supported 30% margin, and round up to the nearest credit micro. Token models
  are charged per million-token provider rates; hidden reasoning/output tokens
  are billed as output when the provider reports `totalTokens` greater than
  visible input plus output tokens. ElevenLabs speech and sound effects use
  provider-returned billing units when available, while music uses request
  duration when the request fixes `music_length_ms`.
- Keep exact/provider-model rate overrides and user limits configurable through
  backend-owned data, not the Mac app.
- Usage records may store sanitized provider usage metadata and normalized
  billable units. They must not store prompts, request bodies, screenshots,
  generated assets, provider output payloads, provider output references, or
  other user content.

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
