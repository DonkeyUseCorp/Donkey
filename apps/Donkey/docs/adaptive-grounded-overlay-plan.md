# Adaptive grounded pointer overlay — implementation plan

## Context

Donkey can drive scriptable apps via AppleScript (e.g. Music, now playing reliably through the
`music-media` skill). But:

- **Electron / non-scriptable apps** (Spotify, Slack, Discord, VS Code) have no useful AppleScript
  dictionary, so the AppleScript path can't act on them.
- Users also ask **"show me where X is" / "how do I X"** — a guidance intent where Donkey should
  *point*, not act.

The pointer overlay must therefore be **grounded in accessibility, decoupled from the execution
backend**. AppleScript is one way to *act*; the overlay only needs *coordinates*, which come from
the accessibility (AX) tree — available for native **and** Electron apps. The harness must
**self-select** the strategy rather than have it hard-wired.

## Goal

The harness figures out, per turn:

```
Classify intent:
  "show me / how do I / where is X"  → GUIDANCE
  "do X" (play, open, send, …)        → ACTION

GUIDANCE → AX-grounded cursor path, overlay only (realPointerMoved=false). No input.

ACTION:
  1. Target app scriptable + skill/AppleScript available → AppleScript (today's path).
  2. App not scriptable (Electron) OR AppleScript fails/blocked
       → AX + screenshot fallback: observe → resolve target control → grounded path
         → move real pointer + click/type (input backend, focus+safety guards)
         → overlay tracks the pointer → verify.
```

## What already exists (reuse, don't rebuild)

| Capability | Where |
| --- | --- |
| Cursor overlay window + animation | `PointerCoachCursorOverlayController` (Donkey), `PointerCoachCursorOverlayView`/`…ViewModel` (DonkeyUI) |
| Visualize tool (grounded steps → overlay request) | `agent.path.visualize` in `GenericHarnessBuiltInToolExecutors`; `AgentPathStep`/`AgentVisualizationPlan` (DonkeyContracts) |
| Overlay presented from a run result | `UserQueryOverlayModel.agentVisualizationPresenter` consumes `result.cursorOverlayRequest` (and streaming `agentVisualizationChanged`) |
| AX element frames | `MacAccessibilitySnapshotCaptureService`, `LocalAppAccessibilityControls` (`frame: WindowTargetBounds`) |
| Screen→normalizedTarget grounding | `LocalAppObservationGeometry.normalizedStepBounds` / coordinate mapper |
| Real input (mouse + keyboard via CGEvent) | `MacKeyboardActionEngineInputBackend` (`leftMouseDown/Up`, keyboard) |
| Engine selection | `LocalAppTaskActionEngines.keyboardOrAutomation(for:)` |
| Safety guards | `ActionEngineGuardrails` / `ActionEngineConfiguration.liveInputEnabled`, focus guard, `targetIsSafeForInput` |
| Live-run → visualization | `LocalAppTaskAgentVisualizationBuilder.plan(for:)` (currently grounds at window level → `noGroundedTargets`) |

The gap is the **decision logic** plus an **AX-grounded path builder** that resolves a target
control to element-level `normalizedTarget` coordinates (today grounding only reaches window level,
which is why skill/AppleScript runs produce `noGroundedTargets`).

## Design / new components

### A. Intent classification (GUIDANCE vs ACTION)
- Add a `guidance` route alongside `localAppTask`/`conversation`/`clarification` in the planner
  (`HostedTaskIntentParsingAdapter` instructions + `generic_harness_planning` schema route enum,
  `TaskIntentWireCodec`). Guidance = "show/point/where is/how do I", no state change.
- Guidance carries the target app + a target description (what to point at), no action payload.

### B. AX-grounded path builder (the shared foundation) — new in DonkeyRuntime
`AccessibilityCursorPathBuilder` (working name):
- Input: target app + ordered list of target descriptions (label/role/text).
- Observe via `MacAccessibilitySnapshotCaptureService` (works for Electron — Chromium AX), discover
  controls with frames via `LocalAppAccessibilityControls`.
- Resolve each description to the best-matching control (reuse `LocalAppTextNormalizer` matching).
- Normalize each control `frame` → `normalizedTarget` `HotLoopRect`/`HotLoopPoint`
  (`LocalAppObservationGeometry`).
- Emit grounded `AgentPathStep[]` (kind `.targetControl`/`.act`, `source: .accessibility`,
  `status: .observed/.executed`).
- Returns `nil`/`blocked` for ungrounded targets (overlay refuses to invent motion — existing tool
  contract).

### C. Strategy router + automatic fallback
- **Capability detection**: is the target app scriptable? Signals: app-finder catalog control
  profile / a known-scriptable allowlist (Music, Notes, …) vs Electron markers; plus **runtime**
  signal — AppleScript generate returns `canGenerate=false`/blocked or `automation.applescript.execute`
  / `skill.script.execute` fails.
- Router (in `UserQueryCommandHandler` run path / `executeGenericHarnessLoop`):
  - GUIDANCE → builder (B) → `agent.path.visualize` → overlay; never run input.
  - ACTION scriptable → AppleScript (today).
  - ACTION non-scriptable OR AppleScript failed → builder (B) → execute grounded path via input
    backend (pointer move + click/type) with guards; overlay tracks.

### D. Action execution on Electron (real input)
- Use `MacKeyboardActionEngineInputBackend` (CGEvent mouse move + click, keyboard) driven by the
  grounded path's screen coordinates.
- Gate with `ActionEngineConfiguration.liveInputEnabled` + focus guard + `targetIsSafeForInput`.
- Overlay (`realPointerMoved=true` here, or mirror) tracks the executed path.

### E. Overlay wiring
- Guidance/visualization already flows: result `cursorOverlayRequest` →
  `UserQueryOverlayModel.agentVisualizationPresenter` → controller. Ensure the guidance route and
  the AX-action path both populate `cursorOverlayRequest`/stream `agentVisualizationChanged`.

## Phased implementation (each independently verifiable)

1. **AX-grounded path builder (B).** New `AccessibilityCursorPathBuilder` + unit tests with a
   synthetic AX snapshot (element frames → expected `normalizedTarget` steps). No app needed.
2. **Guidance route + overlay (A, E).** Planner emits `guidance`; handler builds path via (B) and
   shows the overlay; no input. Verify live on an Electron app ("show me the search box in Spotify")
   — pointer animates to it, nothing is clicked.
3. **Strategy router + fallback (C).** Capability detection + AppleScript-failure fallback wired in
   the run loop. Verify: Music still uses AppleScript; a non-scriptable app routes to the AX path.
4. **Electron real-pointer action (D).** Execute the grounded path with the input backend + guards;
   overlay tracks. Verify live: "play <song> on Spotify" moves the pointer to the result and clicks.

## Verification

- Unit: builder grounding math (synthetic AX frames → normalized steps); router decision table
  (guidance/action × scriptable/non-scriptable × applescript-ok/failed).
- Live smoke (env-gated, like `MusicPlaybackLiveSmokeTests`): guidance overlay on Spotify (phase 2);
  AX action on Spotify (phase 4). Requires Spotify installed + Accessibility granted to the runner.

## Risks / open questions

- **Real input is safety-sensitive** (moves the actual mouse/clicks). Phase 4 stays behind
  `liveInputEnabled` + focus guard; default off outside explicit live runs.
- **Element resolution quality** on Electron: AX labels can be sparse; may need the screenshot +
  local-UI-understanding fallback (`strategyOrder: accessibility,windowMetadata,screenshotForLocalModel`)
  to locate controls when AX is thin.
- **Capability detection** accuracy (scriptable vs not) — start with an allowlist + runtime failure
  fallback; refine over time.
- Environment for live demo: Spotify must be installed/running and the runner AX-granted.
