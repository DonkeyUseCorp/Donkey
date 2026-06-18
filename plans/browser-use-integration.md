# Browser Automation via Browser Use Cloud

## Context

Donkey can read the web (`web.fetch` → clean markdown, `web.search`) but cannot
*act* on it: log in, click through a flow, fill a form, or render a JS-heavy page
to a faithful PDF/screenshot. The `web-capture` skill today only covers static
capture and depends on the user having Chrome installed.

We will add real browser automation by integrating **Browser Use Cloud** — a
managed API for AI browser automation (stealth Chromium, proxies, CAPTCHA, auth
profiles) — in the backend, and exposing it to the Mac app as a hosted harness
tool, the same shape as `web.fetch`. The app never runs a browser; the backend
calls Browser Use Cloud and returns the result.

**Why Cloud, not self-hosted:** the open-source `browser-use` library needs
Python + Playwright + a managed Chromium fleet (heavy infra, scaling, stealth,
proxies). The Cloud API removes all of that for a per-task fee. We mirror how
`HostedWebFetch` already proxies a backend capability.

## Browser Use Cloud — the facts we build against

- Base URL `https://api.browser-use.com`, **API v3** (v2 is legacy — do not use).
- Auth: header `X-Browser-Use-API-Key`, keys start with `bu_`. Server-side secret
  only.
- SDKs: TypeScript `browser-use-sdk` (`import { BrowserUse } from
  "browser-use-sdk/v3"`) and Python. Our backend is TS, so use the TS SDK.
- Run a task: natural-language task + options (starting URL, allowed domains, max
  steps, model, **structured output schema** for typed JSON results). Tasks are
  long-running (seconds to minutes).
- Results: final output text, validated structured JSON, live preview + recording
  URL, and files the agent downloaded (workspaces).
- Async signals: **webhooks** (`agent.task.status_update`, signed with
  `X-Browser-Use-Signature` = HMAC-SHA256 over `"{timestamp}.{sorted-json}"`,
  plus `X-Browser-Use-Timestamp`; reject if older than 5 min) and live message
  streaming. Sessions/profiles persist browser state (cookies/logins) across
  follow-up tasks.
- OpenAPI spec: `https://docs.browser-use.com/cloud/openapi/v3.json` — use it as
  the source of truth for exact request/response fields during implementation.

## Architecture

```
app harness tool  →  Donkey backend route  →  Browser Use Cloud
  web.automate         /api/browser/*            api.browser-use.com/api/v3
  (DonkeyAI)           (site/, withDonkeyAuth)    (X-Browser-Use-API-Key)
```

- **App tool (`DonkeyAI`)**: a `HostedBrowserAutomation` client + a `web.automate`
  registry tool, parallel to `HostedWebFetch`. The planner provides a typed goal
  (task text, optional start URL, allowed domains, optional structured-output
  schema, desired artifacts: none / pdf / screenshot). Safety class is
  **externally-visible action** → it goes through the standard consent gate, never
  silent.
- **Native capture tool (`DonkeyRuntime`)**: a `web.snapshot` tool backed by
  `WKWebView` that loads a URL in-process and exports a PDF (`createPDF`) or PNG
  (`takeSnapshot`). No dependency, no Cloud charge, works on every Mac. This is a
  middle rung of the capture ladder below.

### Capture ladder (free first, paid last)

For page → PDF / screenshot, never reach for paid Cloud until the free engines
can't do it. The `web-capture` skill drives this order:

1. **Local Chromium** (`shell_exec` headless `--print-to-pdf` / `--screenshot`) —
   only if the user already has Chrome/Brave/Edge installed. Free.
2. **Native `WKWebView`** (`web.snapshot`) — always available, in-app, free.
3. **Browser Use Cloud** (`web.automate`) — only when both above fail (heavy bot
   protection, login wall, geo/proxy needs). Costs credits.

Agentic automation (navigate/click/fill/extract, multi-step) has no local
equivalent, so it goes straight to Cloud (Phase 2).
- **Backend (`site/`)**: routes behind `withDonkeyAuth`, queries in
  `src/queries/`, any tables in a grouped `site/prisma/BrowserTasks.prisma`
  (no hand-written SQL/migrations):
  - `POST /api/browser/run` — validate, gate on credits, call Browser Use Cloud
    to start a task, persist a row, return `{ taskId, status }`.
  - `GET /api/browser/run/:id` — return `{ status, output, structured,
    recordingUrl, files }`.
  - `POST /api/browser/webhook` — verify the HMAC signature + timestamp, then
    update the task row when Cloud reports completion (so the GET is fast and we
    avoid hammering Cloud with polls).
- **Async model**: start → return `taskId`; the app's `web.automate` tool polls
  `GET /api/browser/run/:id` using the harness's existing waiting state until the
  task reaches a terminal status or a bounded timeout. Webhooks keep the backend
  row fresh; the app polls our backend, not Browser Use.

## Secrets, cost, and safety (decide before building)

- **`BROWSER_USE_API_KEY`** lives only in backend env / secrets — never in the app
  bundle or repo (OSS).
- **Billing (required)**: Browser Use Cloud cost is **variable per task**, not a
  flat fee — V3 (the version we use) is token-based at ~1.2× the underlying LLM
  rate plus a $0.01/task init; a run is ~5–30 steps. So we bill it exactly like
  every other provider in Donkey: **pass the actual Cloud task cost through at the
  standard 1.3× margin** (`provider-pricing.ts`), debited *after* completion via
  `recordInferenceUsage`, not a hand-set price. Flow:
  - **Preflight**: `requireInferenceCredits` + require balance ≥ a worst-case
    ceiling derived from a per-task `maxSteps` cap (so a runaway task can't
    surprise-bill); 402 when short.
  - **Bound + disclose**: cap `maxSteps` per task; show the worst-case credit
    estimate and the target domains in the consent gate before running.
  - **Debit actual**: on the completion webhook, debit the real Cloud cost × 1.3
    via `recordInferenceUsage` (route `/api/browser/run/`, provider
    `browser-use`), reconciling the preflight hold. Add a `browser-use` entry to
    the provider pricing so the 1.3× margin + ceil-rounding apply automatically.
  - **Free rungs never charge**: local Chromium and `WKWebView` capture cost
    nothing; only `web.automate` Cloud runs debit credits.
  - Implementation check: confirm the task result/webhook returns the task's
    cost (or step/token counts) — see `openapi/v3.json`. If cost is returned,
    pass it through directly; if only steps/tokens, price from those.
- **Data/privacy**: the task text, target sites, and any credentials pass through
  Browser Use's servers. Call this out to users for automation tasks; keep
  credential/login flows behind explicit consent and prefer Browser Use
  **profiles** / human-in-the-loop for auth rather than passing raw passwords.
- **Domain scoping**: default `allowedDomains` to the task's target so a run can't
  wander; surface the consent with the domains it will touch.

## Phasing

- **Phase 1 — the capture ladder.** Build the free rungs first: the native
  `web.snapshot` (`WKWebView` → PDF/PNG) tool, and confirm the local-Chromium path
  in the `web-capture` skill. Then add `web.automate` (Cloud) as the paid fallback
  for pages the free engines can't render, plus structured extraction for pages
  `web.fetch` can't read. Wire the three backend routes, credit gating, and
  consent. Update the `web-capture` skill to encode the ladder (Chromium →
  `WKWebView` → Cloud) and keep `web.fetch` for static markdown.
- **Phase 2 — agentic automation.** Cloud-only multi-step tasks
  (navigate/click/fill), follow-up tasks in a session, profiles for persistent
  auth, and human-in-the-loop for approvals/payments. Likely its own capability
  skill (`web-automation`) describing when to use it vs. the read/capture tools.

## Files (anticipated)

- `apps/Donkey/Sources/DonkeyAI/HostedBrowserAutomation.swift` (new; mirrors
  `HostedWebFetch.swift`)
- a `WKWebView`-backed `web.snapshot` capture tool in `DonkeyRuntime` (new)
- registry tool wiring for `web.automate` and `web.snapshot` (alongside `web.*`)
- `site/src/app/api/browser/run/route.ts`, `…/run/[id]/route.ts`,
  `…/browser/webhook/route.ts` (new)
- `site/src/queries/browser.ts`, `site/prisma/BrowserTasks.prisma` (new)
- `apps/Donkey/Sources/DonkeyRuntime/Resources/BuiltInSkills/web-capture/SKILL.md`
  (point rich capture at `web.automate`); a new `web-automation` skill in Phase 2

## Verification

- Backend: a route test that starts a task against Browser Use Cloud (test key)
  and returns a terminal result; webhook signature verification unit test
  (reconstruct `"{timestamp}.{sorted-json}"`, timing-safe compare).
- App E2E: "save this JS-heavy page as a PDF" (Phase 1) and "go to <site> and
  extract <fields> as JSON" — confirm the consent gate appears with the target
  domains, the artifact returns, and a credit is debited.

## Decisions

- **Credits**: every Browser Use Cloud run is accounted for and debited from
  Donkey credits; the free capture rungs are not. _(decided)_
- **Capture ladder**: local Chromium → `WKWebView` → Browser Use Cloud, paid only
  as the last resort. _(decided)_

- **Pricing model**: pass the actual Browser Use task cost through at Donkey's
  standard 1.3× margin (debit-after-completion), bounded by a `maxSteps` cap — not
  a flat hand-set fee. _(decided)_

Still to settle before Phase 1:

1. The `maxSteps` cap (cost ceiling) and the worst-case estimate shown at consent.
2. **Sync-poll vs webhook-only** for result delivery (plan assumes both: webhook
   updates the row, app polls our backend).
