# Cut

Cut is a standalone video editor served at `cut.donkeyuse.com` (`cut.localhost` in dev). It is a free product that runs on local resources: editing, transcription, export, and the AI assistant all use tools and logins already on the machine that serves it. Cut shares the site's Next.js app for hosting only — it does not touch Donkey's accounts, credits, sign-in, or database.

**The one rule:** Cut stands alone. No Donkey login, no credit metering, no shared tables — for now. So the unauthenticated routes and the local-disk storage are the design, not a gap to patch. Don't wrap Cut's API routes in the Donkey auth helper, reach for Prisma, or bill against credits to "harden" them; that coupling is what this boundary keeps out until Cut stops being local and free.

## How it works

Cut and the Donkey marketing site are one deployment. A request is split by host: only the Cut subdomain reaches the editor.

```
request
  │
  ▼
host is cut.donkeyuse.com / cut.localhost ?
  │ no ──▶ Donkey site (unchanged)
  │ yes
  ▼
rewrite page paths to /cut/*        (api paths pass through untouched)
  │
  ▼
Cut editor (browser)  ──▶  shared /api tree  ──▶  local resources on the serving machine
```

The browser renders the editor; the machine that serves Cut does the heavy work — encoding, transcription, and AI all run there, against local binaries and CLI logins.

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

Because storage is local disk and AI rides the serving machine's CLI logins, Cut is a local product: it runs where those resources live, not on ephemeral serverless hosts. Serving it on a public host would expose the unauthenticated routes and burn the operator's own AI logins, so keep it local until it gets its own auth and storage.

## Where it lives

The editor and its server code sit under the site app's Cut folder; its pages and API handlers mount under the shared route tree, and host-based routing lives in the site's middleware.
