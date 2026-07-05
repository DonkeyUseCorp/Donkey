# Cut

Cut (publicly "Donkey Cut") is a standalone, free video editor. The hosted domain `cut.donkeyuse.com` serves only its client bundle — every page is client-rendered — and the page does all real work against the engine running on the user's own Mac: local disk, local ffmpeg, on-device speech, and the user's own Claude/Codex CLI logins. Cut shares the site's Next.js app for hosting only — it does not touch Donkey's accounts, credits, sign-in, database, or hosted models.

**The one rule:** Cut's server side runs only on the user's Mac. On a hosted deploy every Cut API answers 404 before any handler runs, so the unauthenticated routes are unreachable there and nothing can execute off-Mac — including any path to Donkey's production models, which Cut has none of. Don't wrap Cut's API routes in the Donkey auth helper, reach for Prisma, or bill against credits to "harden" them; local-only is the design.

## How it works

The hosted domain and the local engine split the work: the page comes from wherever is convenient, the work always happens on the Mac.

```
page from cut.donkeyuse.com (hosted)      page from cut.localhost (local dev)
  │  client bundle only;                    │  one local server:
  │  every Cut API 404s there               │  pages + APIs, same origin
  ▼                                         ▼
browser ──────────── API calls ──────────▶ engine on the user's Mac (127.0.0.1)
                                            │
                                            ▼
                              local disk · ffmpeg · on-device speech
                              · the user's own claude/codex CLI logins
```

The engine grants the hosted origin cross-origin access, and only that origin. Loading the page from the hosted domain without a running engine shows a "start Donkey Cut on this Mac" state instead of a broken editor.

## Boundary with Donkey

Cut lives in the same repo and app but shares nothing with the Donkey product yet.

| Concern | Donkey | Cut |
| --- | --- | --- |
| Sign-in | Required account | None |
| Billing | Credits | Free |
| Storage | Database | Local disk |
| Runtime | Hosted routes + Mac app | Local machine only |

The only shared code runs one way: Cut uses a few site UI utilities. Nothing in the Donkey site imports Cut, and Cut adds no database models.

## Local resources

Cut assumes the machine serving it is a Mac with these tools present. Missing tools disable the matching feature; they don't affect the rest of the site.

| Feature | Needs |
| --- | --- |
| Encode, probe, thumbnails | `ffmpeg`, `ffprobe` |
| Transcription / subtitles | `swiftc` and Apple's on-device speech (recent macOS) |
| AI assistant | the operator's own `claude` and `codex` CLI logins |
| Projects, library, exports | writable local disk under the app's working directory |

Because storage is local disk and AI rides the user's own CLI logins, the engine runs where those resources live — never on hosted infrastructure. That boundary is enforced twice: the site's proxy 404s every Cut API path on a hosted deploy, and the engine's disk and process-spawning code refuses to run there.

## Where it lives

The editor and its engine code sit under the site app's Cut folder; its pages and API handlers mount under the shared route tree. Host routing, the hosted API shut-off, and the CORS grant all live in the site's proxy file (`src/proxy.ts`, the Next 16 successor to middleware), with the engine-side guard beside the Cut server code.
