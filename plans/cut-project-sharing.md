# Cut Project Sharing (Read-Only Links)

## Context

Let a Cut user share a video project the way a Google Doc is shared: a stable
link, "anyone with the link can view", revocable, with room to grow into
invitees and roles later. V1 is read-only.

Sharing is a **cloud-only capability**. A cloud project's doc lives in Postgres
(`CutProject.doc`, versioned) and its media in R2 behind presigned GETs, so a
viewer can be served entirely from the hosted deploy. A local project lives on
the owner's Mac behind an engine that answers only on `127.0.0.1`; there is
nothing a viewer on the internet can reach. The backend seam's capability flags
(`site/src/cut/lib/backend/types.ts`) hide the share affordance for local
projects.

**The one rule:** the share surface is read-only by construction — it contains
GET routes only, so there is no write path to guard.

## Design

**Live-follow, not snapshots.** Read-only viewing has no concurrent-edit
problem, so the viewer reads the same doc row the owner autosaves. The doc GET
already returns `x-cut-doc-version`; the viewer polls the version cheaply
(~10s) and refetches the doc when it bumps. The viewer trails the owner by at
most one autosave plus one poll interval. A frozen snapshot is a later option
(copy the doc JSON into the share row); a durable one must also copy media the
way `duplicate()` does, which doubles R2 usage against the owner's quota — so
it waits for demand.

**Stable link, mutable permissions.** Like Google Docs, the URL survives
settings changes. One persistent `CutShare` row per project holds a
high-entropy token; enabling, revoking, and settings changes mutate the row,
never the token. Revocation is a row update; re-enabling restores the same
link.

**Single editor.** The owner is the only writer, ever, in this design. The
share surface has no doc write; "copy project" gives a viewer their own
project, not access to the owner's.

**Settings are a JSON config, not columns.** Share options will keep changing,
so the row carries one `settings Json` column read through a typed
`ShareSettings` parser with defaults — unknown keys ignored, missing keys
defaulted. Adding a toggle is a type + default change, never a migration.

### Share settings (v1)

| Setting | Default | Meaning |
| --- | --- | --- |
| `allowCopy` | off | Viewer can copy the project into their own cloud account |
| `showAiChats` | off | Shared view shows the AI assistant panel |
| `advanced.showMediaTab` | off | Media tab visible to viewers |
| `advanced.showGenTabs` | off | Video / Image / Audio generation tabs visible |

The Library tab is never shown to viewers — it is the owner's per-user
library, so this is an invariant, not a setting. The Details (publish) tab is
likewise always hidden; its data is stripped from the shared doc.

Enforcement is server-side where it matters: doc sanitization reads the share
settings, so a hidden surface's data never leaves the server — tab toggles are
not merely UI. `allowCopy` gates the copy route on the server.

Two settings need honest caveats:

- **`showAiChats`** — chat threads today persist in the owner's browser
  localStorage, per project; the server never sees them. So in v1 this toggle
  can only govern whether the assistant *panel* exists in the shared view (and
  a signed-out viewer cannot run chats anyway — Gemini turns need a session
  and credits). Showing the owner's chat history to viewers requires moving
  thread persistence server-side first; the toggle name is chosen so that
  semantics can grow into it without a settings change.
- **`allowCopy`** — copying requires the viewer to sign in (the copy lands in
  *their* cloud account and counts against *their* quota). It is the one share
  route that is session-authed: `POST /api/cut-share/:token/copy` reuses the
  `duplicate()` mechanics cross-user — copy the sanitized doc and the media
  objects into the viewer's account.

```text
owner (session-authed)                     viewer (no account)
  │                                           │
  │ POST /api/cut-cloud/projects/:id/share    │ opens /app/shared/:token
  ▼                                           ▼
CutShare: token → (userId, projectId)      /api/cut-share/:token/*  (unauthenticated)
                                              ├─ GET doc         (sanitized)
                                              ├─ GET media/:file (302 → presigned R2 GET)
                                              └─ GET preview
```

### Pieces

1. **Schema.** `CutShare { id, token @unique, userId, projectId @unique,
   settings Json, revokedAt, createdAt, updatedAt }` in a sibling `.prisma`
   file per repo rules. Token is crypto-random (not a cuid — cuids are not
   secrets).

2. **Owner routes** on the existing `cut-cloud` table: create/fetch the share
   for a project, revoke it, re-enable it, update its settings.

3. **Viewer routes.** New namespace `/api/cut-share/:token/*` — its own small
   route table through `matchRouteTable`, mounted in its own Next catch-all
   *without* `withDonkeyAuth` (viewers have no session). Each handler resolves
   token → share row, rejects revoked, then reuses the `projectsCloud` read
   paths. It must be a new namespace: `/api/cut/*` 404s on hosted deploys by
   design, and `cut-cloud`'s catch-all is auth-wrapped.

4. **Doc sanitization.** The stored doc carries owner-private fields — notes,
   publish settings, `genvideo` prompts, UI state. The share doc endpoint
   returns a stripped copy limited to what playback needs — assets, clips,
   audioClips, overlays, subtitles, aspect, fades, name — widened only where a
   share setting turns a surface on. The share GET also returns the effective
   settings so the viewer page renders the right chrome from one response.

5. **Viewer page.** `/app/shared/:token` binds the client-rendered editor's
   preview player and timeline to a third backend driver: kind `"share"`,
   rewrites engine-shaped paths to `/api/cut-share/:token/*`, every capability
   flag false plus a read-only flag that hides all editing chrome. Tab
   visibility comes from the served share settings, with Library and Details
   hard-off. Playback and scrubbing already only read the doc and stream
   media.

6. **Copy route.** `POST /api/cut-share/:token/copy`, session-authed, enabled
   by `allowCopy`: sanitized doc + media objects copied into the signed-in
   viewer's account against their quota.

7. **Share UI.** A share dialog in the editor for cloud projects: copy link,
   link on/off, the copy and AI-chats toggles, and an "Advanced" section for
   the tab toggles. Hidden for local projects.

## Build order

1. `CutShare` schema (with `settings Json`) + owner create/revoke/settings
   routes + viewer routes with settings-aware doc sanitization.
2. Viewer page with the share driver, live-follow polling, and settings-driven
   tab visibility.
3. Copy route + viewer copy flow.
4. Share dialog in the editor.

## Later rungs (out of scope for v1)

- **Invite specific people** — invitee list on the share row, checked against
  the viewer's Donkey session.
- **Owner chat history for viewers** — needs chat threads persisted
  server-side first (today they live in the owner's localStorage);
  `showAiChats` then grows into it.
- **Freeze a share** — copy doc JSON into the row; media-copying durability
  only if demanded.
- **Comments** — viewers write comments, not the doc; separate table, no
  concurrency impact.
- **Edit access** — a real multi-writer problem (the 409-and-reload autosave
  assumes one writer); design separately. V1 is single-editor by construction.
