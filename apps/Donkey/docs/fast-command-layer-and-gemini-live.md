# Fast Donkey: tool-first Command Layer + always-on Gemini Live

> **Status: implemented end to end.** Command Layer (Phase 1) and the always-on Gemini Live
> session (Phase 2) are built, unit-tested, and wired into the overlay. The backend mints
> short-lived Vertex AI OAuth tokens (`POST /api/inference/live-token/`), the client connects
> directly to the Vertex Live websocket with a Bearer token, text/audio route through the session,
> tool calls execute against the Command Layer, and the mic can stream continuously. Gemini Live is **enabled by default** and takes over once it
> connects; if it can't authenticate it stays disconnected and the existing pipeline runs
> unchanged. Remaining work is live end-to-end verification with real credentials + mic.

## Context

Donkey is text-first, but slow to *act*. Historically it could only act two ways: generate
AppleScript (a second model round-trip) or fall into a vision loop that screenshots and
re-prompts every turn with a fixed 1.2s sleep (`UserQueryCommandHandler.swift:727`, `:805`).
There was no fast "just do it" substrate — no `open`, no native command.

The goal: **tool-first, screen-last.** Give the model a set of fast, deterministic native tools,
and let an always-on Gemini Live session drive them from text (audio optional), only looking at
the screen when a task genuinely needs visible state.

```
text  (always)  ─┐
audio (optional) ─┤→  Gemini Live session  ──tool call──▶  Command Layer  ──result──▶  back to Live
screenshot (only when needed) ─┘     (fast, native, in-process; no screenshot/AX)
```

## Phase 1 — Command Layer

Fast native, in-process tools the model calls directly. Under ~500ms, no screenshot, no AX tree.
A deliberately small set:

| Tool | Implementation |
|---|---|
| `shell_exec` | runs a safe, single-line shell command via `/bin/zsh -c` and returns its output — the primary, general-purpose tool |
| `apps.list` | reuses `MacLocalAppAvailabilityProvider.installedApplications()` (Spotlight-backed, names + bundle ids) + running apps so the model targets exact names instead of guessing |
| `music.play` | reuses the bundled, pre-validated `music-media` `play-media-by-search.applescript` (a multi-step search→play workflow a one-liner can't reproduce) |

`shell_exec` is the **primary, general-purpose tool** (the same capability the competitor's
Realtime setup exposes) — listed first and prioritized in the system instruction. It handles most
requests directly: opening/quitting/controlling apps (`open -a Spotify`, `osascript -e '…'`),
changing settings, opening URLs (`open https://…`), and reading system state. Earlier dedicated
tools (`app.open`, `app.quit`, `browser.open_url`, `system.set_volume`) were **removed** as
redundant once `shell_exec` could do them reliably; only the two that earn their keep remain —
`apps.list` (discovery is awkward via raw shell) and `music.play` (encapsulated workflow). The
model is told to send only safe single-line commands; a backstop guardrail in
`DonkeyCommandBackends` enforces single-line input, a length cap, and a hard ~12s timeout
(SIGTERM→SIGKILL). Unsafe commands are caught by a **command-word** check on each pipeline/segment
leading executable (so bare `rm`, `/bin/rm`, or a denied command inside `$(…)` is caught) plus a
short list of dangerous substrings (`do shell script`, `| sh`, redirects to `/dev`/`/system`/…) —
chosen over the earlier substring denylist, which both missed bare destructive commands and
false-positived on benign redirects.

Tool results are returned to the Live model in full — `status`, `summary`, the execution metadata
(`stdout`, `stderr`, `exitCode`, `reason`), and any clarification `question` — so it can read
output and self-correct, or ask the user when a tool needs input.

**Where it lives / how it's wired.** `DonkeyHarness` only depends on `DonkeyContracts` and can't
import AppKit, so it follows the codebase's existing injected-closure pattern (like
`appleScriptExecutor`):

- `DonkeyHarness/DonkeyCommandLayer.swift` — tool descriptors + the shared `Command` enum
  (single source of truth for the command names).
- `DonkeyRuntime/DonkeyCommandBackends.swift` — the native side effects.
- Injected via a new `HarnessBuiltInToolServices.commandExecutor` closure, wired in
  `LocalAppUserQueryHarnessServices.builtInSkillBackedServices()`.
- Dispatched from the `default` branch of `BuiltInHarnessToolExecutors.execute` (before
  `unknownTool`), and merged into `BuiltInHarnessToolCatalog.descriptors` so the tools surface to
  the model automatically (they're `.reversible`/`.guardedInput`, so the planner's tool-name
  filter keeps them).

This removes the AppleScript-generation hop and the vision loop for common commands.

## Phase 2 — Always-on Gemini Live session

A single Live session is the command brain. **Text input is always available; audio is an
optional second input** (the existing `MicrophoneWaveformMeter` gained an additive
`onAudioFrames` hook). Tool calls map to the Command Layer; screenshots are sent in-band only
when a task needs visible state.

Files (`DonkeyAI/` unless noted):

- `AIRealtimeSession.swift` — transport-agnostic protocol + event model (parallel to the
  request/response `AIHTTPClient`; this one is a persistent socket).
- `GeminiLiveSession.swift` — `URLSessionWebSocketTask` actor: setup advertising the Command
  Layer tools, context-window compression, session resumption, and transparent `goAway`/drop
  reconnect.
- `GeminiLiveProtocol.swift` — `JSONSerialization`-based message builders + tolerant event parser
  for the `BidiGenerateContent` wire format.
- `CommandLayerFunctionDeclarations.swift` — maps `HarnessToolDescriptor` → Gemini function
  declarations.
- `GeminiLivePCM.swift` — mono float32 → raw 16kHz PCM16 LE (Live's input format).
- `GeminiLiveConfiguration.swift` — env config (below).
- `Donkey/GeminiLiveVoiceController.swift` — owns the session, runs the tool-call loop against a
  Command Layer `HarnessToolRegistry`, and routes anything the model didn't tool-call back to the
  normal pipeline via `onComplexRequest`.

### Routing decision — no string matching

Per requirement, the execution path is **always the model's decision**. There is no phrase table
or deterministic prefilter: the Live model chooses a tool call (act now) vs. asking for the screen
(visual task) vs. a plain reply. The speedup comes from the model *preferring* a fast tool, not
from bypassing it.

### Authentication — Vertex OAuth only

The backend authenticates to **Vertex AI with Google Cloud OAuth (service-account) credentials**,
and the Live client uses the same. There is no client-held API-key path. `GeminiLiveSession`'s
connection provider calls `DonkeyBackendInferenceClient.mintLiveConnection()` →
`POST /api/inference/live-token/`. The backend route (`site/src/app/api/inference/live-token/route.ts`)
uses the shared service-account JWT (`site/src/lib/inference/vertex-live.ts`, `cloud-platform`
scope) to mint a short-lived access token and returns it with the Vertex Live websocket URL
(`{location}-aiplatform.googleapis.com`, or `aiplatform.googleapis.com` for `global`) and the
fully-qualified model path. The client connects with `Authorization: Bearer <token>`; the
long-lived credential never leaves the backend, and the token is re-minted on every (re)connect so
it stays fresh. The result is carried in a single `GeminiLiveConnection` (url + bearer + model).

### Configuration

| Variable | Where | Meaning |
|---|---|---|
| `GEMINI_LIVE_ENABLED` | client | Always-on Live session. **On by default**; set falsey to opt out. |
| `GEMINI_LIVE_AUDIO` | client | Also stream microphone audio (optional). Off by default. |
| `GEMINI_LIVE_MODEL` | backend | Live model id (default `gemini-3.1-flash-live-preview`). Owned solely by the backend — the single source of truth. |
| `GOOGLE_APPLICATION_CREDENTIALS_JSON` | backend | Vertex service-account JSON used to mint tokens. |
| `GEMINI_VERTEX_LOCATION` | backend | Vertex location (default `global`). |

## How the overlay is wired

`UserQueryOverlayModel` owns a `GeminiLiveVoiceController`, started on init (gated by
`isEnabled`). `submitCommand` routes through the session whenever `liveController.isConnected`:
text goes to `sendText`; the model's tool calls run against the Command Layer and report a short
status back via `onActed`; anything not satisfied by a tool call comes back through
`onComplexRequest` → the full local pipeline (`runLocalCommand`, never re-entering Live). When the
session isn't connected, `submitCommand` runs the local pipeline exactly as before.
`UserQueryOverlayController` streams the mic's `onAudioFrames` into the session via
`streamLiveAudioFrames` (no-op unless audio is enabled and connected); a batch voice transcript is
dropped while audio is streaming to avoid double-handling.

## Continuous audio

When `GEMINI_LIVE_AUDIO` is enabled and the session connects, the model fires
`onLiveAudioStreamingChanged(true)`; `UserQueryOverlayController` calls
`MicrophoneWaveformMeter.startContinuousListening()`, which keeps the engine running (and ignores
UI-driven `stop()`s) so audio streams beyond the voice-capture window. Tear down via
`stopContinuousListening()`.

## Configuration recap

Live runs against Vertex AI using backend-minted OAuth tokens (no client-held API key). Enable/audio
are client toggles (`GEMINI_LIVE_ENABLED` on by default, `GEMINI_LIVE_AUDIO` opt-in). The backend
route needs `GOOGLE_APPLICATION_CREDENTIALS_JSON` and optionally `GEMINI_VERTEX_LOCATION` /
`GEMINI_LIVE_MODEL`.

## Testing

This environment needs the full Xcode toolchain and a suite filter:

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GeminiLiveTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GenericHarnessTests
```

(A no-filter full run hangs on a GUI-dependent suite.) Covered today: Command Layer descriptors
surface + input validation (`GenericHarnessTests`), and Gemini Live config parsing, function
declarations, PCM packing, and frame parsing (`GeminiLiveTests`). `GenericHarnessTests` has 8
failures that pre-date this work (confirmed via a clean-tree `git stash -u` re-run).
