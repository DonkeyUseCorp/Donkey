# User Query Overlay

The user query overlay is Donkey's floating macOS surface: a top-center notch
status area, a centered prompt composer, and spawned agent cursors that show
what each task is doing. It is how every typed, voice, and follow-up turn
enters the agent harness.

**The one rule:** the overlay narrates; it never acts. Overlay panels are
non-interactive, non-activating visualization — cursor playback animates only
to grounded evidence coordinates and never synthesizes real mouse movement.
Live keyboard, Accessibility, and AppleScript actions run only through the
guarded runtime (`docs/guides/agent-harness.md`).

## Startup Gate

First launch shows a native welcome screen, then a Google-only Mac sign-in.
Until the browser returns through `donkey://auth/callback` and the app
exchanges the code for a Better Auth cookie, the notch is not shown and
double-Command activation is not registered. `DonkeyAuthCoordinator` and
`DonkeyLoginWindowController` own the sign-in gate.

The welcome window gates a first install only — a Mac that has never signed
in. Once a Mac has signed in at least once, an expired session is handled in
the notch instead of the window: the overlay comes up with the notch logged
out, and its Login button restarts the same Google flow. The auth phase
drives this, so the notch flips back to the task surface the moment sign-in
completes. A session that expires mid-run — a hosted request returning 401 —
trips the same path live: the notch flips to login while the running tasks
stay put, then resumes showing them after sign-in.

## Activation and the Prompt

- Double-tap Command and release: centered prompt with keyboard focus, no
  microphone capture.
- Double-tap Command and hold the second press: the same prompt with voice
  active.
- Voice capture starts only from explicit activation — the hold, or pressing
  the microphone affordance. The controller records bounded local audio and
  publishes levels; transcription is model-backed through the hosted harness
  boundary before transcript text enters the turn path.
- The composer is a compact black surface: single-line text is pill-shaped,
  multiline text becomes a bounded rounded rectangle. Return submits,
  Shift-Return inserts a newline, Escape and outside clicks dismiss, and
  non-input capsule areas drag the modal. Typed text promotes the send button
  and makes the microphone affordance secondary.

Double-Command always opens the centered prompt, even when spawned cursors are
visible. If a cursor is selected, centered typed or voice input attaches to
that task; otherwise Donkey uses the latest interactable cursor before falling
back to follow-up resolution.

## Notch Surface

The notch shows task progress, recent tasks, follow-up input, file drops,
update availability, and per-task pause/resume. File drops attach to the
active or most recent task. Task actions — follow-up submission, pause/resume —
cross the model/controller boundary with the selected task ID.

Geometry comes from the active `NSScreen`, preferring safe-area and
auxiliary-top metrics over hardcoded notch sizes. Content stays out of the
physical notch void; displays without a notch use the same top-center
composition without reserving unavailable space. `UserQueryNotchLayout` is the
shared source for surface frames, content frames, corner radii, and notch-safe
offsets; `canRenderTextInTopRow` describes whether text can draw in the top
row, not whether that row exists.

## Spawned Cursors

Submitting a typed prompt or notch follow-up shows a spawn cue: the notch
arrow rotates toward the exit direction, leaves the notch, and a Donkey cursor
travels onto the desktop.

- Cursors travel to a known safe visible target window when one exists;
  otherwise they hold about 250 px below the notch near screen center as a
  thinking state and retarget when the destination becomes visible.
- A stationary cursor shows the submitted turn while Donkey works, using the
  cursor tail animation as the waiting state instead of interim label text.
  When a response, clarification, review wait, or failure arrives, that text
  replaces the label and stays visible; completed action-only cursors may fade
  out.
- Labels render complete words and wrap to their measured size — no partial
  typewriter text, no clipping at the panel edge. They expand wider on hover
  when that reduces wrapping, and select the cursor on click.
- Clicking a tasked label turns the same agent-colored surface into an inline
  editor: the agent message above, a lighter color-matched input below. Return
  submits the follow-up to that spawn's task, Shift-Return inserts a newline,
  Escape returns to the label, and clicking outside closes the editor.
- Multiple cursors can be present at once. The newest is selected by default;
  clicking a cursor or its label selects it as the current agent.

## Turn Path

Prompt submissions, voice transcripts, and follow-ups all take the same
agent-harness path: task-thread routing, context assembly, one-shot request
understanding, then the per-step harness loop that responds, clarifies, or
executes guarded action. See `docs/guides/decision-system.md` for how the
decision is made.

- Local-item requests resolve against installed apps, files, and folders using
  the SQLite agent memory store, Spotlight/`mdfind`, and bounded filesystem
  fallback. A missing item stays safe and reports not-found instead of falling
  back to a vague clarification.
- Scriptable app tasks prefer guarded AppleScript before Accessibility, AI
  visual targets, or keyboard input. Completion is verified through the
  generic verification policy, not visible result text for every app.
- Conversation contents persist as markdown under Application Support
  (`Conversations/<id>/conversation.md`); Core Data stores durable conversation
  metadata, events, and assets for per-run runtime coordination.
- Command handling emits actionable `com.donkey.app` route/result logs:
  submitted commands, routing decisions, action traces (backend, input mode,
  whether an element click happened, the control or bounds target, and that
  the overlay pointer is visual-only), unsupported requests, unavailable apps,
  and final task status.

## Agent Memory Store

A background store in Application Support records resolved and missing
local-item lookups, prewarms apps, and stores runtime task definitions with
metadata such as kind, path, bundle ID, source, task, and action. It is SQLite
with FTS5 plus deterministic local embeddings; JSONL is an explicit
export/debug format only. A bounded set of matching hints feeds the harness
memory section for model consideration. Prewarming runs off the main actor and
never eagerly scans protected folders. Cached local-item hits must still point
to an existing path or bundle before they are used as an execution target.

## Visualization

Cursor playback uses only grounded evidence: observed Accessibility or
action-trace control bounds, converted from target-window-normalized centers
into the active overlay screen's pixel coordinates. Before each travel segment
the pointer rotates toward the direction of travel, then moves along a curved
path with compact labels while the real mouse stays untouched. Harness
playback flows through `agent.path.visualize`, which returns a plan only after
every waypoint is grounded; ungrounded steps are omitted. Visual-only
demonstration turns use the same plan shape without live input, and a
visualization-only cursor is used only when no spawned cursor is available to
attach to.

The developer UI inspection overlay is separate from agent visualization: a
transparent, non-activating, click-through, keyboard-pass-through panel at a
lower window level than Donkey's interactive UI. It renders local detector
output only and itself rejects provider action calls (click, type, scroll,
drag, `computer_call`, `function_call`). Enable it by editing the repo-tracked
`apps/Donkey/dev-overlay.json` during debug runs or by creating
`~/Library/Application Support/Donkey/dev-overlay.json`; production builds do
not bundle the repo config and honor only the Application Support path. No
config, an invalid config, or `"enabled": false` fully disables it. See
`docs/guides/donkey-vision.md` for the config shape and fusion behavior.

## Division of Labor

| Component | Owns |
|---|---|
| `UserQueryOverlayModel` | product state and typed intents |
| `UserQueryOverlayController` | AppKit surfaces, placement, hover tracking, focus, shortcut recognition, dismissal, file-drop routing, microphone level capture |
| `DonkeyUI` (SwiftUI) | rendering from `DonkeyContracts` state — no parsing, model calls, input execution, or screen/microphone capture |
| `UserQueryCommandHandler` | turn routing, outcome handling, route/result logging |

Spawn display state is typed state: the model emits progress, target hints,
and current selection; the controller resolves hints against safe visible
windows; SwiftUI renders the cue, cursors, labels, label-to-editor transition,
and selection.

## Verification

Manually verify after overlay changes:

- Startup: welcome → sign-in; the notch and double-Command activation appear
  only after sign-in completes.
- Activation: release opens focused text input without microphone capture;
  hold opens voice mode; the microphone affordance starts capture; unrelated
  Command use does not activate the overlay.
- Notch: renders top-center, respects physical notch safe areas, expands only
  from visible notch hover, accepts expanded controls and clicks; file drops
  attach to the right task.
- Spawn flow: cue → travel → tail-wag waiting → result label; retargeting when
  the target becomes visible; persistent labels for attention states; fade-out
  only for completed action-only turns; labels wrap without clipping; the
  inline editor opens, submits, and closes correctly.
- Multiple cursors: clicking selects; double-Command still opens the centered
  prompt and routes the turn to the selected/latest cursor's task without
  opening the inline editor.
- Turns: conversation answers without action failure; local-item opens launch
  the item and missing items report not-found with the lookup provider and
  reason; visual-only prompts animate without moving the real pointer;
  completion claims match the runtime verification state.
- Dev overlay: with `dev-overlay.json` enabled, clicks, typing, scrolling,
  dragging, and prompt activation still target the underlying app or Donkey
  UI; removing the config or setting `"enabled": false` hides the overlay
  without relaunching.

## Source Entry Points

- App orchestration starts in `apps/Donkey/Sources/Donkey/`.
- Typed prompt command handling lives in
  `apps/Donkey/Sources/Donkey/UserQueryCommandHandler.swift`.
- Reusable SwiftUI rendering lives in `apps/Donkey/Sources/DonkeyUI/`.
