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
- SDK (verified, `browser-use-sdk@3.8.4`): `new BrowserUse({ apiKey })`, then
  `client.sessions.create(body)` to start and `client.sessions.get(id)` to poll.
  `body` (camelCase, mapped to snake_case): `task`, `startUrl`, `allowedDomains`,
  `maxSteps`, `model`, `structuredOutput`/`schema`.
- `SessionResponse` fields we use: `id`, `status`
  (`created → idle → running → stopped | timed_out | error`), `output`
  (free-form string OR structured object when an output schema was given),
  `stepCount`, `isTaskSuccessful`, `recordingUrls`, `liveUrl`, `lastStepSummary`.
- **No webhooks — polling.** The API has no task-completion webhook; the SDK
  polls `sessions.get`. So our app polls our backend, and our backend polls
  Browser Use. (Earlier draft assumed webhooks; corrected.)
- **No per-task USD cost field.** The response exposes `stepCount`, and Browser
  Use bills `$0.01 init + per-step`. So we price by steps (see billing).

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
- **Backend (`site/`)**: one route behind `withDonkeyAuth`:
  - `POST /api/browser/run` — validate, preflight credits, then
    `client.run(task, …)` which executes the task to completion **server-side**
    (the SDK polls Browser Use on our server), charge credits by `stepCount`, and
    return `{ status, isTaskSuccessful, text, structured, recordingUrl, liveUrl,
    stepCount }`. `maxDuration = 300`; `maxCostUsd` bounds the task so it finishes
    within that.
- **Synchronous, not polled.** Charging happens here, after the run finishes, and
  never depends on the client. The app makes one blocking call and waits — no GET
  poll route, no cron sweep, no `BrowserRun` table (the credit usage event is the
  audit record). The only residual edge is a task that exceeds `maxDuration`
  (rare, bounded by `maxCostUsd`); accepted rather than reintroducing
  client-driven settlement.

## Secrets, cost, and safety (decide before building)

- **`BROWSER_USE_API_KEY`** lives only in backend env / secrets — never in the app
  bundle or repo (OSS).
- **Billing (required)**: the API exposes no per-task USD cost, but it does
  expose `stepCount`, and Browser Use bills `$0.01 init + per-step`. So we price
  **by steps** at Donkey's standard 1.3× margin: a `browser-use` provider-pricing
  entry with `generationCostMicros = usdWithMargin(<per-step USD>)`, charged via
  `recordInferenceUsage` with `usage = { generationCount: stepCount }`. Flow:
  - **Preflight**: `requireInferenceCredits` (402 when the balance is empty),
    consistent with the other inference routes; the actual debit is after the run.
  - **Bound**: `maxCostUsd` caps the Browser Use spend per run, which also keeps a
    run within `maxDuration`. (No bespoke consent gate — `web.automate` is
    `.sensitive` and the skill instructs confirming login/pay turns.)
  - **Charge at completion, server-side**: when `client.run` returns (terminal),
    debit `stepCount × per-step × 1.3` via `recordInferenceUsage` (route
    `/api/browser/run/`, provider `browser-use`) in the same request. One request
    = one charge, so no idempotency dance. Browser Use bills steps even on
    failure, so charge regardless of `isTaskSuccessful`.
  - **Free rungs never charge**: local Chromium and `web_snapshot` cost nothing;
    only Cloud `web.automate` runs debit credits.
  - Per-step rate tracks the default model's published per-step price; fold the
    $0.01 init into the rate. Revisit if Browser Use later exposes exact cost.
- **Data/privacy**: the task text, target sites, and any credentials pass through
  Browser Use's servers. Call this out to users for automation tasks; keep
  credential/login flows behind explicit consent and prefer Browser Use
  **profiles** / human-in-the-loop for auth rather than passing raw passwords.
- **Scoping**: v3 has no `allowedDomains` field — the target site is expressed in
  the task prompt (and `startUrl` is folded in). `maxCostUsd` is the spend bound.

## Phasing

- **Phase 1 — the capture ladder (done).** The native `web_snapshot`
  (`WKWebView` → PDF/PNG) free rung, the local-Chromium path in the `web-capture`
  skill, and `web.automate` (Cloud) as the paid fallback + structured extraction
  for pages `web.fetch` can't read, with synchronous credit charging. The
  `web-capture` skill encodes the ladder (Chromium → `WKWebView` → Cloud) and
  keeps `web.fetch` for static markdown.
- **Phase 2 — agentic automation.** Cloud-only multi-step tasks
  (navigate/click/fill), follow-up tasks in a session, profiles for persistent
  auth, and human-in-the-loop for approvals/payments. Likely its own capability
  skill (`web-automation`) describing when to use it vs. the read/capture tools.

> The **local** counterpart to Phase 2 — driving the user's own Chrome over CDP
> with the open-source `browser-use` CLI (real sessions, no bundled Chromium) —
> is planned separately in `plans/local-browser-cdp-automation.md`. It augments
> this Cloud path with a free "act in your own browser" rung.

## Files (implemented)

- `apps/Donkey/Sources/DonkeyAI/HostedWebAutomate.swift` — single blocking call;
  `DonkeyBackendInferenceClient.runBrowserTask`
- `web_snapshot` (`WKWebView` → PDF/PNG) in `DonkeyCommandBackends.swift` +
  descriptor in `DonkeyCommandLayer.swift`; `web.automate` descriptor + executor +
  `webAutomator` service in the harness
- `site/src/app/api/browser/run/route.ts` (synchronous POST)
- `site/src/lib/browser/{client,models,pricing}.ts`;
  `site/src/lib/credits/{provider-pricing,inference}.ts` (browser-use pricing +
  route). No `BrowserRun` table — the credit usage event is the audit record.
- `BuiltInSkills/web-capture/SKILL.md` (ladder) + `BuiltInSkills/web-automation/SKILL.md`

## Verification

- Built + checks green: `swift build`, `swift test --filter SkillInstallTests`,
  site `tsc --noEmit`, `eslint`.
- E2E (needs `BROWSER_USE_API_KEY` on a deploy): "save this JS-heavy page as a
  PDF" (free `web_snapshot` rung), and "go to <site> and extract <fields> as
  JSON" (`web.automate` — confirm the result returns and a credit is debited by
  `stepCount`).

## Decisions

- **Credits**: every Cloud run is debited from Donkey credits, **server-side at
  completion** (never client-driven); free capture rungs aren't charged. _(done)_
- **Capture ladder**: local Chromium → `WKWebView` → Browser Use Cloud, paid only
  as the last resort. _(done)_
- **Pricing**: charge `stepCount × per-step × 1.3` (per-step + cap centralized in
  `browser/pricing.ts`); `maxCostUsd` bounds spend. _(done)_
- **Delivery**: synchronous — the backend runs the task to completion and charges
  in the one request; no polling, webhooks, or cron. _(done)_
- **No consent gate** for `web.automate` (per product call). _(done)_

Open follow-ups:

1. Tune the per-step rate (`browser/pricing.ts`, `$0.02`) and the `maxCostUsd`
   cap (`$0.5`) against real Browser Use bills once it's live.
2. Phase 2: follow-up tasks in a session, profiles for persistent auth,
   human-in-the-loop — its own `web-automation` depth beyond single tasks.
