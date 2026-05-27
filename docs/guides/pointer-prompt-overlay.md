# Pointer Prompt Overlay

## Supported Behavior

Donkey supports a floating macOS overlay for conversational task threads and
quick local-app actions:

- On first launch, Donkey shows a native welcome screen, then a Google-only Mac
  sign-in screen, then a native permission setup screen for Accessibility,
  Screenshots, and Microphone before starting the overlay. Until the browser
  returns through the `donkey://auth/callback` handoff, the app exchanges the
  returned code for a Better Auth cookie, and the core permission setup is
  complete, the notch surface is not shown and double-Command activation is not
  registered.
- Double-tap Command and release to open a centered prompt with keyboard focus.
- Double-tap Command and hold the second press to open the prompt in voice mode.
- Show a top-center notch status surface for task progress, recent tasks, follow-up input, file drops, updates, and per-task pause/resume.
- When a typed prompt or notch follow-up is submitted, show a task spawn cue: the notch arrow rotates toward the exit direction, moves out of the notch, and a Donkey cursor overlay travels onto the desktop.
- Spawned cursors travel to a known safe visible target window when one is available. Otherwise they hold about 250 px below the notch near screen center as a loading/thinking state, then retarget if the destination becomes visible.
- Multiple spawned cursors can be present at the same time. The newest spawned cursor is selected by default, and clicking a cursor or its label selects it as the current agent.
- A stationary spawned cursor shows the submitted turn while Donkey is waiting on routing, model, or runtime work; it uses the cursor tail animation as the waiting state instead of replacing the label with interim text. When a response, clarification, review wait, failure, or other attention state is available, that result text replaces the label and stays visible so the user can read it and follow up; completed action-only cursors may fade out. Labels render complete words and wrap to their measured size instead of revealing partial typewriter text or clipping at the panel edge. Spawn labels expand wider on hover when that reduces wrapping, and select the cursor on click. Clicking a tasked label turns the same agent-colored surface into an inline editor with the agent message above and a lighter color-matched user input area below; Return submits the typed follow-up to that spawn's task, Shift-Return inserts a newline, Escape returns to the label, and clicking outside the editor closes it.
- Double-Command always opens the centered prompt, even when spawned cursors are visible. If a spawned cursor is selected, centered typed or voice input attaches to that task behind the scenes; otherwise Donkey uses the latest interactable spawned cursor before falling back to follow-up resolution.
- Keep prompt submissions, voice transcripts, and follow-ups on the same agent-harness path: task-thread routing, context assembly, conversational response, clarification, review, catalog-backed action parsing, task validation, and guarded local-app execution when a turn is actionable.
- Resolve model-classified local-item requests against local apps, files, and folders by querying the current Mac with the SQLite-backed agent memory store, Spotlight/`mdfind`, and bounded filesystem fallback. If the requested local item cannot be found, keep the task safe and report that it was not found instead of falling back to a vague clarification.
- Handle scriptable app tasks as guarded AppleScript automation when possible. Commands may use task metadata, generated source, or compact templates; completion is verified through generic task verification policy instead of requiring visible result text for every app.
- Visualize agent work with the spawned task cursor when a submitted turn already has one. Normal local-app tasks keep planning in the background and may create a final `AgentVisualizationPlan` only from runtime evidence such as evidence-backed action steps, observations, and action traces. Cursor playback uses only grounded control bounds or action targets, so it does not animate to invented coordinates. Visual-only demonstration turns use the same plan shape without live input. Local-app visualizations use observed Accessibility or action-trace control bounds when available, convert target-window-normalized element centers into the active overlay screen's pixel coordinates, and only then move the overlay cursor. Donkey moves the overlay cursor along curved paths and shows compact labels next to it while keeping the real mouse untouched. A separate visualization-only cursor is only a fallback when no spawned cursor is available to attach to.
- Maintain a background agent memory store in Application Support. The store records resolved and missing local-item lookups, prewarms apps, stores runtime task definitions, keeps metadata such as kind/path/bundle ID/source/task/action, indexes records with SQLite FTS5 plus local vectors, and passes a bounded set of matching hints into the agent harness memory section for classifier and model consideration. Protected file folders such as Desktop, Documents, and Downloads stay lazy and are searched only when a user-requested local-item lookup needs them. See `docs/guides/decision-system.md` for how those hints feed typed model decisions and guarded local-app plans.
- Persist task threads as searchable Core Data conversations with event history, task assets, and per-run runtime coordination for any action work attached to the thread.
- Keep the overlay non-invasive. Permission setup requests Accessibility, screenshot, and microphone access with user-visible reasons, but the overlay itself does not capture the screen or synthesize input directly. Bounded screenshots and Accessibility reads are used only by guarded local-app workflows.
- A developer-only Donkey Vision overlay can be enabled by editing the
  repo-tracked `apps/Donkey/dev-overlay.json` during debug runs, or by creating
  `~/Library/Application Support/Donkey/dev-overlay.json`. Production builds do
  not bundle the repo config and only honor the Application Support path. When
  no config exists, the config is invalid, or `"enabled": false`, the debug
  overlay is fully disabled. When enabled, Donkey Vision fuses Accessibility and
  hosted AI screenshot parsing. Local geometry wins; AI boxes are read-only
  evidence and are visually marked as `AI`. The overlay never sends a full
  desktop screenshot to hosted AI: it captures safe app/window or
  system-navigation surfaces only. See
  `docs/guides/donkey-vision.md`.

```json
{
  "enabled": true,
  "mode": "donkeyVision",
  "cadenceSeconds": 1.0,
  "screenScope": "main",
  "minConfidence": 0.25
}
```

## Technical Guidelines

- `PointerPromptOverlayController` owns AppKit surfaces, placement, hover tracking, focus, keyboard shortcut recognition, dismissal, file-drop routing, and microphone level capture.
- `DonkeyAuthCoordinator` and `DonkeyLoginWindowController` own the Mac sign-in
  gate. `MacPermissionSetupWindowController` owns the post-auth core permission
  gate. App startup should create the overlay controller only after a stored
  Google session exists or a pending sign-in callback validates its state token
  and stores a Better Auth cookie in the app cookie jar, and the permission
  setup has completed.
- SwiftUI rendering lives in `DonkeyUI` and consumes state/contracts from `DonkeyContracts`. It should not perform command parsing, model calls, input execution, screen capture, or microphone capture.
- `PointerPromptOverlayModel` owns product state. Durable task data is persisted through Core Data in Application Support.
- Spawn display state is typed state. The model emits progress, target hints, and current selection; the overlay controller resolves hints against safe visible windows and keeps voice capture on the centered prompt; SwiftUI renders the notch cue, cursors, labels, label-to-editor transition, and selection state.
- Notch geometry comes from the active `NSScreen`, preferring safe-area and auxiliary-top metrics over hardcoded notch sizes. Content must stay out of the physical notch void; displays without a physical notch should use the same top-center composition without reserving unavailable space.
- `PointerPromptNotchLayout` is the shared source for notch surface frames, content frames, corner radii, and notch-safe offsets. `canRenderTextInTopRow` describes whether text can draw in the top row, not whether that row exists.
- The prompt is a compact black composer: single-line text is pill-shaped, multiline text becomes a bounded rounded rectangle, Return submits, Shift-Return inserts a newline, Escape and outside clicks dismiss, and non-input capsule areas can drag the modal.
- The centered composer keeps text and voice modes on the same input surface. Double-Command release opens focused text input, double-Command hold opens the same input with voice active, and typed text promotes the send button while the microphone affordance becomes secondary.
- Voice capture and transcription remain separate. The controller records bounded local audio and publishes levels; transcription is model-backed through the hosted agent-harness boundary before transcript text enters the turn path.
- Local item prewarming must run off the main actor and must not eagerly scan protected user folders. Agent memory is stored in SQLite under Application Support and uses FTS5 plus deterministic local embeddings for retrieval; JSONL is only an explicit export/debug format. Cached local-item hits must still point to an existing path or bundle before they are used as an execution target. Runtime task definitions are the generic open/local-app interaction seeds plus generated or user-reviewed definitions loaded from memory.
- For scriptable apps, prefer app-native AppleScript task commands before falling back to Accessibility or keyboard input. Submit steps with an explicit structured `controlID` may execute as an Accessibility `AXPress` against button-like controls, with the control bounds carried into action traces. Bounded screenshots may supplement observation/verification according to task metadata, but screenshots remain context evidence and do not directly drive input.
- Agent visualization overlays are non-interactive, non-activating panels. They may point, explain, and replay what the agent is doing or would do, but they do not synthesize mouse movement. Live keyboard or Accessibility actions remain separate guarded runtime actions. When a local-app action plan is based on an observation, preserve target-window geometry and control bounds on the evidence-backed steps so cursor replay can use pixel-grounded element positions instead of invented coordinates.
- The developer UI inspection overlay is separate from agent visualization. It
  is a transparent, non-activating, click-through, keyboard-pass-through AppKit
  panel at a lower window level than Donkey's interactive UI. It renders
  CALayer rectangles and labels from local Accessibility or hover-probe detector
  output only. Provider action calls such as click, type, scroll, drag,
  navigation, `computer_call`, or `function_call` are rejected instead of
  executed. Hover-only detections are visualization/read-only evidence and must
  not become live input authority.
- Task actions in the notch, including follow-up submission and pause/resume, must cross the model/controller command boundary with the selected task ID.
- Pointer prompt command handling should emit actionable `com.donkey.app` route/result logs for submitted commands, routing decisions, intent resolution, local action traces, unsupported requests, unavailable apps, and final task status. Action trace logs should state the backend, input mode, whether an element click happened, the control or bounds target, and that the overlay pointer is visual-only.

## Verification

Manually verify:

- The notch renders at the top center, respects physical notch safe areas, expands only from visible notch hover, and accepts expanded controls/clicks.
- First launch shows the permission setup after sign-in, explains Accessibility, Screenshots, and Microphone before requesting them, enables Continue only when all three are ready, and does not trigger Desktop/Documents/Downloads prompts during startup.
- Double-Command release opens a centered focused text prompt; double-Command hold opens the same prompt with voice active; typed text shows a primary send button and a secondary microphone affordance; unrelated Command use does not activate the overlay.
- Typed, voice, and follow-up submissions create or update durable task threads, answer non-actionable conversation without showing action failure, show action status in the notch when work runs, and preserve per-task pause/resume behavior.
- Typed prompt and notch follow-up submissions show the spawn sequence: notch cue, desktop cursor emergence, direct travel to a known target or fallback holding point, typed submitted-turn label with tail-wag waiting animation, final response/result label, retargeting when the target becomes visible, persistent labels for conversational or attention states, and fade-out only for completed action-only turns.
- Stationary spawn labels render complete text without typewriter clipping, wrap to fit available width, select the cursor on click, and transition in place into a same-styled inline editor for tasked follow-ups without clipping the carried-over label.
- With multiple spawned cursors visible, clicking a cursor selects it; double-Command still opens the centered prompt, and the submitted typed or voice turn routes to the selected/latest cursor's task without opening the inline label editor.
- Open requests for installed apps, files, and folders launch or open the local item; missing local items show a not-found result and log the lookup provider/reason.
- LLM-classified visual-only prompts complete as visualization turns and show the animated cursor with typed labels without moving the real pointer.
- Normal local-app tasks can produce final visualization steps for observed, navigated, acted, and verified runtime work. Planning stays in the background. Cursor playback should target observed control centers from Accessibility or action traces when those bounds exist, omit ungrounded steps, and must not claim completion unless the runtime verification state supports it.
- The prompt supports wrapping, Shift-Return newline insertion, Return submission, Escape dismissal, outside-click dismissal, and dragging from non-input areas.
- File drops on the notch attach to the active or most recent task.
- With `dev-overlay.json` enabled, interact with underlying applications while
  the debug boxes are visible; clicks, typing, scrolling, dragging, and Donkey
  prompt activation should continue to target the underlying app or Donkey UI.
  Removing the config file or setting `"enabled": false` should hide the debug
  overlay without relaunching.

## Source Entry Points

- App orchestration starts in `apps/Donkey/Sources/Donkey/`.
- Typed prompt command handling lives in `apps/Donkey/Sources/Donkey/PointerPromptCommandHandler.swift`.
- Reusable SwiftUI rendering lives in `apps/Donkey/Sources/DonkeyUI/`.
