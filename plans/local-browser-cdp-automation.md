# Local Browser Automation via the browser-use CLI (CDP)

## Context

Donkey can already *act* on the web through `web.automate`, but only via **Browser
Use Cloud**: a paid, isolated cloud Chromium that cannot see the user's logins
(`plans/browser-use-integration.md`, Phase 2). The user wants a local
counterpart — drive **the user's own Chrome** over CDP with the open-source
`browser-use` CLI, reusing their real logged-in sessions, without shipping
Chromium.

This adds a **new free "act in your own browser" rung** beside Cloud. The Cloud
path stays for isolation, stealth, proxies, and the case where the user has no
local Chromium-family browser.

The non-negotiables from the request:

- Use the upstream `browser-use` CLI in its **agentic `run` mode** (its embedded
  agent reasons and loops; Donkey hands it a task, not per-click primitives).
- **CDP-based.** Connect to a running Chrome over the DevTools Protocol; never
  embed or download a browser engine.
- **Do not ship Chromium.** Skip `browser-use install`. Connect to the
  Chrome/Brave/Edge the user already has.
- **Lightweight.** The only thing we bundle is the Python `browser-use` sidecar,
  not a browser. Skipping the ~150 MB Chromium download is the main size win.

## What the CLI gives us (verified against the docs)

- CDP connect modes: `browser-use connect` (auto-discovers a running Chrome),
  `--cdp-url http://localhost:9222` / `ws://...` (explicit endpoint),
  `--profile "<name>"`, `--headed`.
- Agentic mode: `browser-use run "<task>"` drives a full multi-step task. It
  needs an LLM — model + key come from `~/.browser-use/config.json` or env, and
  the LLM endpoint base URL is configurable.
- `--json` for machine-readable output; `--mcp` for a stdio MCP server; config
  home overridable via `BROWSER_USE_HOME`.
- Distribution: `uv pip install browser-use` (Python). `browser-use install`
  fetches Chromium — **we never run that step.**

## The Chrome-debugging constraint (decides session reuse)

Chrome 136+ **refuses `--remote-debugging-port` when the data dir is the default
profile**, and Chrome locks a profile while it is running. So "just attach to the
user's everyday Chrome" is not available. We support two session modes, chosen
per request (the skill teaches the planner which to ask for):

- **Dedicated profile (default).** Launch the user's Chrome binary with a
  persistent, Donkey-owned `--user-data-dir` and a free `--remote-debugging-port`.
  The user signs into sites once in that profile; sessions persist across runs.
  No conflict with their everyday Chrome.
- **Seeded profile (on request).** Copy the user's Default profile (cookies,
  logins) into the Donkey data dir first, then launch as above, so it inherits
  current sessions. Touches sensitive on-disk browser data and can go stale, so
  it is gated on explicit consent and never the default.

## Architecture

```text
user request
   |
   v
Donkey planner  --(web.automate, target: local)-->  LocalWebAutomate (DonkeyRuntime)
                                                          |
                          1. ChromeCDPSession: launch user's Chrome
                             --remote-debugging-port=N --user-data-dir=<profile>
                             (dedicated | seeded), wait for /json/version
                                                          |
                          2. run bundled `browser-use` sidecar:
                             browser-use --cdp-url ws://127.0.0.1:N run "<task>" --json
                             LLM base URL -> Donkey backend proxy (token from app)
                                                          |
                          3. stream step summaries -> overlay; return result text/JSON
                                                          v
                                              user's real Chrome (CDP)
```

Three new pieces of work, one reused.

### 1. The `browser-use` sidecar (packaging)

`browser-use` is Python, so this is the only genuinely new packaging shape. Follow
the existing bundled-tools path (`scripts/fetch-bundled-tools.sh` →
`vendor/donkey-tools/` → signed → published artifact → first-run download into
`~/Library/Application Support/Donkey/donkey-tools/`, on PATH via
`shellEnvironment()`).

- Build a **relocatable Python** (python-build-standalone, the same base `uv`
  uses) with `browser-use` and its deps (incl. Playwright Python, used purely as
  the CDP client) installed into a venv under `vendor/donkey-tools/browser-use/`.
  **Never run `browser-use install`**, so no browser binaries land in the bundle.
- Ship a thin `browser-use` launcher on PATH that execs the venv's interpreter.
  Add it to `BundledTools.executableNames`, and — like `yt-dlp` — to
  `selfExtractingExecutableNames` so `sign-bundled-tools.sh` grants the
  `disable-library-validation` entitlement its native `.so`/dylibs need under the
  hardened runtime.
- Code-sign every dylib/`.so` in the venv (the script already walks and signs the
  vendor dir; extend its coverage and add a smoke test: `browser-use --version`
  and a `--cdp-url` connect against a throwaway Chrome).

This is the heaviest part. "Lightweight" here means *no Chromium*; the Python
runtime + Playwright client is still tens of MB. If that proves too heavy to sign
and notarize cleanly, the fallback seam is `browser-use --mcp` over stdio behind
the same launcher — same packaging, different invocation.

### 2. `ChromeCDPSession` (DonkeyRuntime)

A new type that owns the browser process for a run:

- Resolve the user's Chrome/Brave/Edge binary (do not bundle one); if none is
  found, fail cleanly with a message that points the planner at the Cloud rung.
- Launch headed with a free `--remote-debugging-port` and the chosen
  `--user-data-dir` (dedicated or seeded). For seeded mode, copy the Default
  profile into the Donkey data dir first, behind consent.
- Poll `http://127.0.0.1:N/json/version` for `webSocketDebuggerUrl`; hand that
  to the sidecar.
- Tear down (or keep warm for follow-up turns in the same task). The launched
  Chrome is a child process Donkey controls, separate from the user's everyday
  window.

### 3. LLM routing for the browser-use agent (backend)

The agent's `run` loop needs an LLM. To keep Donkey's rule that *only model
decisions go to the backend* and to avoid shipping a raw provider key in an OSS
app, point browser-use's LLM at a **Donkey backend proxy**:

- The backend exposes an OpenAI-compatible (or Anthropic-compatible) relay behind
  `withDonkeyAuth` that forwards to Donkey's chosen model and **meters credits by
  model tokens** (`recordInferenceUsage`), reusing the existing inference-credit
  machinery (`requireInferenceCredits` preflight → debit on usage).
- The sidecar env sets the base URL to that relay plus a short-lived Donkey token
  the app already holds. No `browser-use` Cloud key, no third-party key on disk.

So a local run is "free" of Browser Use Cloud's per-step fee; its cost is the
agent's **model tokens**, billed through Donkey like any other inference.

### 4. Harness tool + skill (reuse `web.automate`)

- Keep **one** `web.automate` tool. Add a `target: local | cloud` field (plus
  `profileMode: dedicated | seeded` and `headed` for local). Local and Cloud share
  the request shape (task, startURL, schema), so one tool with a selector keeps
  the planner's surface small; the skill teaches when to pick which.
- `target: local` routes to `LocalWebAutomate` (DonkeyRuntime) instead of
  `HostedWebAutomate` (the Cloud backend). The executor orchestrates
  `ChromeCDPSession` + sidecar and streams the agent's step summaries to the
  overlay (the pointer narrates every step — a long browser run must not look like
  a hang).
- **Safety class: sensitive, externally-visible action.** This drives the user's
  *real, logged-in* browser, so it is at least as guarded as Cloud `web.automate`:
  it goes through the consent gate, and login/payment surfaces refuse a silent
  background run and fall back to foreground (the standard input-guard invariant).
  Driving the browser is "controlling another app," so it does **not** run as a
  free trusted read despite being a bundled tool.
- `web-automation/SKILL.md` gains the local-vs-cloud decision: prefer **local**
  when the task needs the user's own sessions or should stay on-device and a
  Chromium-family browser is installed; use **cloud** for isolation, stealth,
  proxies, or when no local browser exists. Document the two profile modes and
  that the dedicated profile needs a one-time sign-in.

## Capture/act ladder (updated)

```text
read         web.fetch            static markdown, free
capture      web_snapshot         WKWebView -> PDF/PNG, free
capture      local Chromium       headless --print-to-pdf, free if installed
act (local)  web.automate local   user's Chrome over CDP, real sessions,
                                   model-token cost only            <-- NEW
act (cloud)  web.automate cloud   isolated cloud browser, per-step credits,
                                   stealth/proxy/no-local-browser
```

## Phasing

1. **Sidecar + CDP smoke path.** Bundle `browser-use` (no Chromium), build
   `ChromeCDPSession`, and prove `browser-use --cdp-url ... run "<task>"` works
   against a launched dedicated-profile Chrome from a throwaway script. LLM keyed
   directly for the spike only.
2. **Backend LLM relay + billing.** Stand up the metered OpenAI/Anthropic-
   compatible relay; point the sidecar at it; debit model-token credits.
3. **Harness tool + consent + overlay.** Add `target`/`profileMode` to
   `web.automate`, wire `LocalWebAutomate`, route through the consent gate, stream
   step summaries to the overlay.
4. **Seeded-profile mode + skill.** Add the consented Default-profile copy and the
   local-vs-cloud guidance in `web-automation/SKILL.md`.

## Files (anticipated)

- `scripts/fetch-bundled-tools.sh` — build the relocatable Python + `browser-use`
  venv; `scripts/sign-bundled-tools.sh` — sign its dylibs / grant the entitlement;
  `BundledTools.swift` — add `browser-use` to the executable + self-extracting
  lists.
- `apps/Donkey/Sources/DonkeyRuntime/ChromeCDPSession.swift` — launch/connect/
  teardown of the user's Chrome over CDP (new).
- `apps/Donkey/Sources/DonkeyRuntime/LocalWebAutomate.swift` — orchestrate session
  + sidecar, stream steps, return result (new); descriptor + `target` routing in
  the harness alongside the existing `web.automate` path.
- `apps/Donkey/Sources/DonkeyHarness/GenericHarnessBuiltInToolExecutors.swift` —
  extend `HarnessWebAutomateRequest` with `target` / `profileMode` / `headed` and
  branch local vs cloud.
- `site/` — a metered, auth'd LLM relay route + `browser-use` token issuance;
  reuse `lib/credits/{provider-pricing,inference}.ts`.
- `BuiltInSkills/web-automation/SKILL.md` — local-vs-cloud decision + profile
  modes.

## Risks / open questions

- **Notarization of a bundled Python.** Many native `.so`s under the hardened
  runtime; the `yt-dlp` precedent (library-validation exception) is the template,
  but `browser-use`'s dependency tree is larger. Confirm a clean
  sign-and-notarize early — this is the likeliest blocker.
- **Chrome version drift.** The default-profile debugging block (v136+) and CDP
  shape can move; pin behavior to a probe of `/json/version` rather than assuming.
- **Seeded-profile freshness + privacy.** A copied profile can hold a stale or
  surprisingly broad session set; keep it consented, scoped, and documented.
- **Relay fidelity.** browser-use expects a specific LLM API surface (tool calls,
  structured output). The relay must pass those through faithfully to whatever
  model Donkey routes to; verify against the model browser-use is configured for.

## Verification

- Build green: `swift build`, `swift test --filter SkillInstallTests`, site
  `tsc --noEmit` + `eslint`.
- Sidecar smoke (build machine): `browser-use --version`; `--cdp-url` connect +
  one-step `run` against a throwaway dedicated-profile Chrome.
- E2E (local Chrome installed): "log into <site I'm already signed into> and pull
  my latest <thing>" with `target: local` — confirm it reuses the session in the
  dedicated profile, narrates steps in the overlay, and debits model-token credits
  (not Browser Use Cloud steps).
