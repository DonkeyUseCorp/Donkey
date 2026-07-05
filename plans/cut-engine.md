# Cut Engine: Hosted Client, Engine Inside the Donkey App

Make cut.donkeyuse.com work for a visitor on a Mac by riding what Donkey already ships. The page serves the whole UI; the Cut engine — the local server doing disk, ffmpeg, on-device speech, and the user's own claude/codex logins — runs on `127.0.0.1:41417`, spawned and supervised by the Donkey Mac app. The app already has signing, notarization, bundled ffmpeg, and a release/update channel; Cut reuses all of it instead of shipping a second artifact.

**The governing principle: zero-ask lifecycle.** The web client drives everything — connection, reconnection, update nudges — and the user is asked nothing beyond what macOS mandates (app install, permission dialogs). Engine updates ride Donkey app releases; no separate updater, no prompts.

## Supported so far

- **Client**: probes `/api/cut/engine/health` on `127.0.0.1:41417` then `:3000` (dev), memoizes the winner, `localStorage["cut-engine-origin"]` override; engine-down screen auto-polls every 3s; all Cut pages client-rendered; chat transport resolves its URL per send; hosted deploys 404 every Cut API; CORS granted to `https://cut.donkeyuse.com` only.
- **Slice 1 — handler core (done)**: every Cut API route's logic lives in framework-free handlers under the Cut server's `http/` folder (web-standard Request/Response), with one route table (`CUT_ROUTES` + `matchCutRoute`) under `/api/cut/*` that both surfaces dispatch through — the engine mounts it directly, and the Next dev server reaches it via a single optional-catch-all route (`/api/cut/[[...slug]]`) that delegates to the shared table. `matchCutRoute` mirrors Next's routing (static-over-dynamic precedence, HEAD via the GET handler, 405 for a known path with no handler for the method), so dev and engine cannot diverge. Data roots are engine-aware: dev keeps `projects/`/`library/` at the checkout cwd; with `DONKEY_CUT_ENGINE` set they move to `~/Library/Application Support/DonkeyCut` (`DONKEY_CUT_DATA_DIR` overrides).
- **Slice 2 — engine binary (done)**: `npm run engine:build` (bun is a devDependency) compiles the engine entry into a single ~62MB Mac binary that mounts the route table on `127.0.0.1:41417`, widens PATH from the app's tools dir + a login shell + common bins, resolves the user's Claude Code install for the Agent SDK, and serves the MCP proxy as its own `mcp-proxy` subcommand. The HTTP layer refuses any browser Origin that isn't the hosted Cut page before a handler runs (a no-Origin same-machine caller is allowed), grants that one origin CORS, aborts a turn only on real client disconnect, and tears down file streams when a download is cut off. The bind port validates `DONKEY_CUT_PORT` and fails loud rather than binding a random port. Health reports `DONKEY_CUT_VERSION` (stamped by the app; "dev" otherwise). Verified end-to-end: health, CORS preflight and origin allowlist, foreign-origin refusal, HEAD/405 parity with Next, project CRUD on the engine data dir, models probe, and the MCP proxy tool-catalog round trip.
- **Slice 4 — speech tool lookup (done)**: transcription resolves a prebuilt `cut-stt` from PATH (the app's bundled tools) first and compiles from source only in dev; a missing tool degrades with a clear message. CI prebuild of `cut-stt` still pends with app packaging below.
- **Slice 5 — install funnel (done)**: the engine-down screen offers "Get Donkey for Mac" and auto-connects when the engine appears. Engine updates ride the Donkey app's own auto-updater — the client shows no update prompt.

## Target

```
cut.donkeyuse.com (static client)         user's Mac
  │                                         Donkey.app (signed, auto-updating)
  │ engine-down screen:                       └─ spawns + supervises
  │ "Get Donkey" / "Open Donkey"                 donkey-cut-engine (:41417)
  ▼                                               ├─ mounts CUT_ROUTES
page polls → connects → works                     ├─ data: ~/Library/App Support/DonkeyCut
                                                  ├─ tools: the app's bundled ffmpeg/ffprobe
                                                  ├─ AI: user's claude/codex logins
                                                  └─ version in /api/cut/engine/health
```

- **Slice 3 — app-side supervision (done)**: the Donkey app spawns the engine at launch regardless of sign-in (Cut is free and standalone), via a supervisor in the runtime module: shell environment from the app's existing helper plus the engine flag, app version stamp, and tools dir; crash restarts with backoff; a health preflight skips spawning when another engine already owns the port; the app's quit path stops it. Engine logs go to the user's Logs folder, size-capped. Staging is one automatic step: the dev run script and release packaging each build the engine (via `site/scripts/build-cut-engine.sh`, which installs site deps if missing) and stage it — dev symlinks it, release copies and signs it with the JIT entitlements a bun binary needs under the hardened runtime. `DONKEY_CUT_ENGINE_BIN` can point at a prebuilt binary to skip the build. The app builds clean with all of it.
- **Slice 6 — docs (done)**: `docs/guides/cut.md` describes the app-hosted engine as supported behavior.

## Verification left

Code-complete and verified as far as this machine allows (engine smoke-tested end-to-end standalone; app + site compile clean; scripts and workflow lint clean). Outstanding before moving this plan to done:

- First nightly run bundles the engine into the dmg — confirm the packaged app spawns it and cut.donkeyuse.com connects.
- `cut-stt` is still compiled on demand in dev; adding a prebuilt to the published tools bundle (publish-bundled-tools workflow) removes the Xcode CLT need on user machines. The engine already prefers a prebuilt from PATH when present.

## What Should Be Done Next

Run a nightly (or local `package-donkey-app.sh`, which now builds and bundles the engine itself), install the dmg, and verify the live path: app launch → engine on 41417 → cut.donkeyuse.com connects and edits. Then move this plan to `plans/done/`.
