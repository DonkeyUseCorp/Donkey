# Cut

Cut (publicly "Donkey Cut") is a standalone, free video editor. The hosted domain `cut.donkeyuse.com` serves only its client bundle — every page is client-rendered — and the page does all real work against the Cut engine: a local server the Donkey Mac app ships and supervises on the user's own Mac. The engine uses local disk, the app's bundled ffmpeg, on-device speech, and the user's own Claude/Codex CLI logins. Cut shares Donkey's hosting and distribution only — it does not touch Donkey's accounts, credits, sign-in, database, or hosted models.

**The one rule:** Cut's server side runs only on the user's Mac. On a hosted deploy every Cut API answers 404 before any handler runs, so the unauthenticated routes are unreachable there and nothing can execute off-Mac — including any path to Donkey's production models, which Cut has none of. Don't wrap Cut's API routes in the Donkey auth helper, reach for Prisma, or bill against credits to "harden" them; local-only is the design.

## How it works

The hosted domain and the local engine split the work: the page comes from wherever is convenient, the work always happens on the Mac.

```
page from cut.donkeyuse.com (hosted)      page from cut.localhost (local dev)
  │  client bundle only;                    │  one local server:
  │  every Cut API 404s there               │  pages + APIs, same origin
  ▼                                         ▼
browser ── API calls ──▶ Cut engine on 127.0.0.1 (spawned by the Donkey app)
                           │
                           ▼
             local disk · bundled ffmpeg · on-device speech
             · the user's own claude/codex CLI logins
```

The client probes the engine's health endpoint (dedicated port first, dev server second) and remembers the winner. The engine grants the hosted origin cross-origin access, and only that origin. Without a running engine the page shows a "get Donkey / open Donkey" state that connects by itself as soon as the engine appears. Engine updates ride the Donkey app's own auto-updater, so the client never prompts to update.

## One API surface, one router

Every Cut API route is a framework-free handler (web-standard request in, response out) registered once in a route table (`matchCutRoute`), namespaced under `/api/cut/*` to keep it clear of Donkey's own APIs. Both surfaces dispatch through that one table: the packaged engine mounts it directly, and the Next dev server reaches it through a single optional-catch-all route (`/api/cut/[[...slug]]`). They are the same router — static-over-dynamic precedence, HEAD, and 405s behave identically, and there is nowhere for the two to drift. The hosted 404 is applied once, in that shared dispatch.

## The engine

The engine is a single compiled binary built from the site's Cut code (`npm run engine:build` in `site/`) and version-locked to the app: the app stamps its own release version into the engine's environment, and updates ride app releases. The Donkey app spawns it at launch — regardless of sign-in, since Cut is free and standalone — restarts it with backoff if it dies, skips spawning when another engine already answers on the port, and stops it on quit. Its data lives under the user's Application Support; its logs under the user's Logs folder.

Because a GUI-spawned process inherits a bare PATH, the engine rebuilds it: the app's bundled tools first (bundled tool always wins), then the user's login-shell PATH and common install dirs. That is how it finds ffmpeg, the user's `claude` and `codex`, and the prebuilt speech tool.

## Boundary with Donkey

| Concern | Donkey | Cut |
| --- | --- | --- |
| Sign-in | Required account | None |
| Billing | Credits | Free |
| Storage | Database | Local disk |
| Model access | Hosted routes | The user's own CLI logins |
| Distribution | The Mac app | Rides the same app |

The only shared code runs one way: Cut uses a few site UI utilities, and the engine rides the app's process-environment helpers. Nothing in the Donkey product imports Cut, and Cut adds no database models.

## Local resources

Missing tools disable the matching feature; they never affect the rest of the site or app.

| Feature | Needs |
| --- | --- |
| Encode, probe, thumbnails | the app's bundled `ffmpeg`/`ffprobe` |
| Transcription / subtitles | prebuilt `cut-stt` from the bundled tools (dev falls back to compiling it) |
| AI assistant | the user's own `claude` and `codex` CLI logins |
| Projects, library, exports | writable local disk (Application Support when run as the engine) |

## Where it lives

The editor, its handlers, and the engine entry sit under the site app's Cut folder; host routing, the hosted API shut-off, and the CORS grant live in the site's proxy file (`src/proxy.ts`, the Next 16 successor to middleware). The app-side supervisor lives with the Donkey runtime code, and the packaging scripts stage the engine binary into the app bundle.
