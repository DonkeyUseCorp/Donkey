# Cut

Cut (publicly "Donkey Cut") is a standalone, free video editor. Its product domain is `donkeycut.com` — a marketing landing at `/` and the editor at `/app/…` — while the legacy `cut.donkeyuse.com` keeps serving the editor at its root, unchanged. Both hosts serve only the client bundle — every page is client-rendered — and the page does all real work against the Cut engine: a local server the Donkey Mac app ships and supervises on the user's own Mac. The engine uses local disk, the app's bundled ffmpeg, on-device speech, and the user's own Claude/Codex CLI logins. Using the app requires a Donkey sign-in, and every engine request carries the signed-in account id: each account's projects and library live in that account's own folder on the Mac, so accounts sharing a machine don't see each other's work. AI generation — images, video, and voiceovers — and the assistant's Gemini models additionally spend credits: the page posts to Donkey's hosted inference routes with the user's session and credits. On `cut.donkeyuse.com` the auth cookie rides the registrable domain; `donkeycut.com` is a different registrable domain, so it signs in through an apex one-time-token handoff (`/cut-auth`) that sets a host-only cookie there. Generated media lands back in the project through the engine like any other file; Gemini chat turns, including their editor tool calls, run entirely in the page.

**The one rule:** Cut's server side runs only on the user's Mac. On a hosted deploy every Cut API answers 404 before any handler runs, so the unauthenticated routes are unreachable there and nothing can execute off-Mac — the engine has no path to Donkey's production models; the page reaches them only through Donkey's own authenticated inference APIs. Don't wrap Cut's API routes in the Donkey auth helper, reach for Prisma, or bill against credits to "harden" them; local-only is the design for everything the engine does.

## How it works

The hosted domain and the local engine split the work: the page comes from wherever is convenient, the work always happens on the Mac.

```
page from donkeycut.com (hosted)          page from localhost/cut (local dev)
  │  client bundle only;                    │  one local server:
  │  every Cut API 404s there               │  pages + APIs, same origin
  ▼                                         ▼
browser ── API calls ──▶ Cut engine on 127.0.0.1 (spawned by the Donkey app)
                           │
                           ▼
             local disk · bundled ffmpeg · on-device speech
             · the user's own claude/codex CLI logins
```

The client probes the engine's health endpoint (dedicated port first, dev server second) and remembers the winner. Browsers permission-gate a hosted page's calls to the local machine, so the first hosted visit holds on a connect screen and fires the browser's permission prompt from the user's own click; a denied permission gets its own recovery screen. The engine grants the hosted origins cross-origin access, and only those origins. Without a running engine the page shows a "get Donkey / open Donkey" state that connects by itself as soon as the engine appears. Engine updates ride the Donkey app's own auto-updater, so the client never prompts to update.

## One API surface, one router

Every Cut API route is a framework-free handler (web-standard request in, response out) registered once in a route table (`matchCutRoute`), namespaced under `/api/cut/*` to keep it clear of Donkey's own APIs. Both surfaces dispatch through that one table: the packaged engine mounts it directly, and the Next dev server reaches it through a single optional-catch-all route (`/api/cut/[[...slug]]`). They are the same router — static-over-dynamic precedence, HEAD, and 405s behave identically, and there is nowhere for the two to drift. The hosted 404 is applied once, in that shared dispatch.

The shared dispatch also binds each request to the account id the page sends, and every project and library path builds on that account's folder — only the health probe runs outside a scope. A request without an id is refused before any handler runs. The engine has no way to verify the id (it never talks to the hosted backend), so this separates accounts that share a Mac; it is not protection against a hostile local user, who owns the disk anyway. Data written before scoping existed is adopted by the first account that connects.

## The engine

The engine is a single compiled binary built from the site's Cut code and version-locked to the app: the app's dev run script and release packaging build and bundle it automatically (no separate step), and the app stamps its own release version into the engine's environment, so updates ride app releases. The Donkey app spawns it at launch — regardless of sign-in, since Cut is free and standalone — restarts it with backoff if it dies, and stops it on quit. The engine's lifetime is tied to the app process: the engine watches the pid that spawned it and exits when that process is gone, and at launch the app replaces an engine on the port stamped with a different version, so engine fixes always ship with the app update. An engine matching the app's version (another instance) or a developer-run "dev" engine is left alone. Its data lives under the user's Application Support, one folder per Donkey account; its logs under the user's Logs folder.

Because a GUI-spawned process inherits a bare PATH, the engine rebuilds it: tools shipped beside the engine binary first (they version with the app), then the app's bundled tools (bundled tool always wins), then the user's login-shell PATH and common install dirs. That is how it finds the speech tool, ffmpeg, and the user's `claude` and `codex`.

## Boundary with Donkey

| Concern | Donkey | Cut |
| --- | --- | --- |
| Sign-in | Required account | Required account; data is per-account on the Mac |
| Billing | Credits | Free; AI generation and Gemini chat spend credits |
| Storage | Database | Local disk |
| Model access | Hosted routes | CLI logins; AI generation and Gemini chat use Donkey's hosted routes (signed in) |
| Distribution | The Mac app | Rides the same app |

The only shared code runs one way: Cut uses a few site UI utilities, and the engine rides the app's process-environment helpers. Nothing in the Donkey product imports Cut, and Cut adds no database models.

## Local resources

Missing tools disable the matching feature; they never affect the rest of the site or app.

| Feature | Needs |
| --- | --- |
| Encode, probe, thumbnails | the app's bundled `ffmpeg`/`ffprobe` |
| Transcription, subtitles, and voice dictation in prompt inputs (assistant, image/video/audio generation) | prebuilt `cut-stt` shipped beside the engine binary (the plain dev server falls back to compiling it); dictation streams live mic audio through its `--live` mode |
| AI assistant | the user's own `claude` and `codex` CLI logins; its Gemini models use a Donkey sign-in and credits instead |
| AI generation (image / video / voiceover) | a Donkey sign-in and credits |
| Projects, library, exports | writable local disk (Application Support when run as the engine) |

## The assistant's knowledge

The AI assistant knows the editor through three surfaces: the catalog — tool definitions, the skills library, and the system prompt, shared by every provider — the browser-side tool implementations that run those tools against the live editor store, and the per-turn context snapshot sent with each message. The catalog lives with the engine's AI code; the implementations and snapshot live with the editor client code. How a chat turn actually runs — providers, the tool bridge, context budgets — is its own guide: [Cut's AI Assistant](ai-assistant.md).

**Teach the assistant in the same change.** When an editor feature lands, changes, or goes away, update those surfaces with it — usually by adding, updating, or deleting the matching tools and skills, and by extending the context snapshot when the feature adds user-visible state. A feature the catalog omits is invisible to the assistant, and a stale tool or skill is worse: the assistant confidently acts on behavior that no longer exists.

## Where it lives

The editor, its handlers, and the engine entry sit under the site app's Cut folder; host routing, the hosted API shut-off, and the CORS grant live in the site's proxy file (`src/proxy.ts`, the Next 16 successor to middleware). The app-side supervisor lives with the Donkey runtime code, and the packaging scripts stage the engine binary into the app bundle.
