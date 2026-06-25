# Backend API Guide

Backend APIs live in `site/src/app/api/**/route.ts`. They serve the Mac app
(session cookie), the site's own client views, and third-party Vision API
developers (API keys).

**The one rule:** every route handler is wrapped in `withDonkeyAuth` from
`@/lib/donkey-api-auth`. A public endpoint is a deliberate exception with an
explicit product reason — today only Better Auth's own routes and the
signature-verified Stripe webhook — never a default.

## Authentication

- `withDonkeyAuth` accepts a Donkey session cookie by default. Third-party API
  keys are opt-in per route: `withDonkeyAuth(handler, { allowApiKey: true })`.
  This typed allowlist is the only way a key reaches a handler — never match on
  the request path. `request.donkey.method` tells the handler how the caller
  authenticated (`session-cookie`, `api-key`, or `dev-bypass`).
- Better Auth is mounted at `site/src/app/api/auth/[...all]/route.ts` and
  configured through `@/lib/auth`. The supported interactive login provider is
  Google OAuth only; keep `emailAndPassword.enabled` false unless the product
  explicitly adds another login method. Configure Google OAuth with
  `${BETTER_AUTH_URL}/api/auth/callback/google` as the redirect URI.
- Mac app sign-in uses Better Auth's one-time-token plugin. `/mac-auth/callback`
  mints a short-lived code from the browser session, renders a browser handoff
  page that opens `donkey://auth/callback`, then the app exchanges the code at
  `/api/auth/one-time-token/verify` so `URLSession` stores the resulting Better
  Auth cookie in the app-owned cookie jar. Keep the code short-lived while
  still allowing a manual "Open Donkey" fallback click, and keep the Mac app
  callback origin (`donkey://` by default) in Better Auth trusted origins.
- In Vercel, configure `BETTER_AUTH_URL`, `BETTER_AUTH_SECRET`,
  `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, and
  `DONKEY_MAC_AUTH_REDIRECT_ORIGINS`. Do not commit real OAuth credentials.

## Handler Rules

- Validate request bodies, search params, and route params with Zod before
  using them.
- Verify resource ownership before reading or mutating scoped data.
- Return explicit `NextResponse.json(...)` responses with the intended status
  code.
- For access-control failures (missing session, missing/inactive subscription),
  return a plain 401 via `unauthorizedResponse`; for a missing resource, a
  plain 404 via `notFoundResponse` (both from `@/lib/donkey-api-auth`). Do not
  write per-case descriptive auth/not-found errors. Reserve distinct status
  codes for genuinely different operational outcomes (e.g. 402 over quota, 429
  rate limit).
- Do not wrap route handlers in `try/catch` unless the handler can recover and
  return a different intentional response. Let unexpected errors surface to the
  framework's logging path.

## Database

- Keep Prisma access server-only through `@/lib/prisma`.
- Keep Prisma table/model definitions in logically grouped sibling `.prisma`
  files under `site/prisma/`. Never put table/model definitions in
  `site/prisma/schema.prisma`; reserve that file for shared Prisma
  configuration such as generator and datasource blocks.
- Use Prisma's default table names for new models; do not add `@@map`. (Some
  earlier tables predate this and keep their mapped snake_case names.)
- Add `@@index` only for a column a query actually filters or joins on. `@id`
  and `@unique` already index their columns, so don't restate those or add
  speculative indexes; an index you don't query is just write overhead.
- Do not run database migrations as part of normal API work.

## Inference Gateway

The inference gateway lives under `site/src/app/api/inference/**`. It is a
Mac-app-facing backend boundary for remote model and asset generation. Routes,
shared schemas, stateless provider calls, and Swift contracts stay
provider-neutral; provider names are configuration/data inside private adapters
only.

- Require `x-donkey-client-id` on inference routes.
- Keep remote asset generation state on the Mac side. The backend can create or
  refresh remote provider jobs and return provider job IDs, provider generation
  IDs, polling URLs, and output references, but it must not persist prompts,
  generation records, provider output references, or generated assets in
  Postgres.
- Keep provider-specific request mapping behind the inference provider registry.
  Route handlers import the registry and neutral schemas, not individual
  adapters.
- Computer-use provider tools are registered as request tools and mapped by
  adapters. Both browser and guarded macOS desktop interaction use Gemini's
  built-in `computer_use` tool: `donkey_gemini_browser_interaction` maps to the
  `ENVIRONMENT_BROWSER` environment and `donkey_gemini_mac_desktop_interaction`
  to `ENVIRONMENT_DESKTOP`, and the adapter returns the model's native action
  calls for the Mac app to execute. Developer-only read-only UI inspection uses
  `donkey_debug_ui_inspection`; adapters route it through hosted
  vision/computer-use-capable models but must not forward or execute UI action
  calls.
- Screenshot parsing is available at `POST /api/inference/screenshots/parse/`.
  It accepts scoped app/window or system-navigation screenshots only, never
  whole-desktop captures, and returns read-only UI evidence in the Mac app's
  local UI understanding shape. The default provider is Gemini Flash through a
  dedicated screenshot-parsing module configured with hosted Google credentials
  or `GEMINI_API_KEY`.
- The Gemini adapter uses the official `@google/genai` Node/TypeScript SDK for
  general non-streaming chat, structured Responses calls, and computer-use calls
  (browser and macOS desktop). It uses Vertex AI's global endpoint only when
  `GOOGLE_APPLICATION_CREDENTIALS_JSON` includes a `project_id`; if the project
  is missing, the provider is unavailable. The adapter's defaults route fast
  structured task-intent and follow-up decisions to `gemini-3.1-flash-lite`,
  and use `gemini-3.5-flash` for general chat, non-decision Responses calls, and
  Computer Use tool calls — computer use is a built-in tool of the main flash
  model, so one model serves both environments. Keep model selection in code
  rather than environment overrides. Structured
  decision requests normalize JSON schemas for Gemini and retry without
  provider-enforced schema when Vertex rejects schema parameters; Mac-side
  runtime validation still owns whether the returned JSON is executable. Set
  `GOOGLE_APPLICATION_CREDENTIALS_JSON` as a hosted-deploy sensitive env var
  rather than storing Google provider credentials in the Mac app.
- The OpenAI hosted Responses adapter uses `OPENAI_API_KEY` only for developer
  read-only UI inspection. Keep that credential in the hosted deployment
  environment; the Mac app must not carry OpenAI provider credentials.

## Hosted Model Credits

Hosted inference usage is metered per authenticated user in the backend. The
Mac app sends provider-neutral inference requests; the backend owns credit
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

## Third-Party Vision API

`POST /api/vision` is also a self-serve product for outside developers, sold
separately from the Mac app. It serves two audiences through the same handler,
branching on `request.donkey.method`:

| Caller | `request.donkey.method` | Gate |
|---|---|---|
| Mac app | `session-cookie` | hosted credit balance, as above |
| Third-party developer | `api-key` | active subscription + monthly call quota — never touches the money-credit balance |

How the third-party path works:

- Developers sign in with Google and subscribe through Stripe. The subscription
  is a flat monthly plan that grants a quota of API calls, stored on
  `VisionApiSubscription` (`site/prisma/Billing.prisma`). The included call
  count comes from the Stripe price metadata (`monthlyCallQuota`).
- Keys are issued by the Better Auth API-key plugin (`@better-auth/api-key`),
  managed from the account settings UI via `/api/api-keys`. Only a hash is
  stored; the secret is shown once. Key creation requires an active
  subscription.
- The vision route opts in with `allowApiKey: true`, enforces a per-key burst
  limit, and counts succeeded vision usage events in the current period against
  the quota. Covered calls are recorded with `billingMode: "included"` (zero
  money cost) so they still appear in usage without debiting credits.
- Stripe is the source of truth for subscription state. `POST /api/billing/webhook`
  is signature-verified and therefore a deliberate public exception to the
  `withDonkeyAuth` rule; it syncs subscription lifecycle and the call quota.
  Checkout, portal, subscription, and usage live under `/api/billing/**`.
- The per-user account views (`/app/settings`, including API keys and usage)
  are client-rendered; all data access goes through the audited TanStack Query
  hooks in `site/src/queries/`.

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
