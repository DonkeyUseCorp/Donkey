# Pointer Prompt Overlay

## Supported Behavior

Donkey supports a floating macOS overlay for conversational task threads and
quick local-app actions:

- On first launch, Donkey shows a Google-only Mac sign-in window before starting
  the overlay. Until the browser returns through the `donkey://auth/callback`
  handoff and the app exchanges the returned code for a Better Auth cookie, the
  notch surface is not shown and double-Command activation is not registered.
- Double-tap Command and release to open a centered prompt with keyboard focus.
- Double-tap Command and hold the second press to open the prompt in voice mode.
- Show a top-center notch status surface for task progress, recent tasks, follow-up input, file drops, updates, and per-task pause/resume.
- When a typed prompt or notch follow-up is submitted, show a task spawn cue: the notch arrow rotates toward the exit direction, moves out of the notch, and a Donkey cursor overlay travels onto the desktop.
- Spawned cursors travel to a known safe visible target window when one is available. Otherwise they hold about 250 px below the notch near screen center as a loading/thinking state, then retarget if the destination becomes visible.
- Multiple spawned cursors can be present at the same time. The newest spawned cursor is selected by default, and clicking a cursor or its label selects it as the current agent.
- A stationary spawned cursor types the submitted turn first, then compact progress or response text in its label. Conversational responses, clarifications, review waits, failures, and other attention states stay visible so the user can read them and follow up; completed action-only cursors may fade out. Spawn labels clamp to two lines by default, reveal the full label on hover only when the collapsed label would truncate, and select the cursor on click. Clicking a tasked label turns the same agent-colored surface into an inline editor with the agent message above and a lighter color-matched user input area below; Return submits the typed follow-up to that spawn's task, Shift-Return inserts a newline, Escape returns to the label, and clicking outside the editor closes it.
- Double-Command always opens the centered prompt, even when spawned cursors are visible. If a spawned cursor is selected, centered typed or voice input attaches to that task behind the scenes; otherwise Donkey uses the latest interactable spawned cursor before falling back to follow-up resolution.
- Keep prompt submissions, voice transcripts, and follow-ups on the same agent-harness path: task-thread routing, context assembly, conversational response, clarification, review, catalog-backed action parsing, task validation, and guarded local-app execution when a turn is actionable.
- Resolve model-classified local-item requests against local apps, files, and folders by querying the current Mac with the SQLite-backed agent memory store, Spotlight/`mdfind`, and bounded filesystem fallback. If the requested local item cannot be found, keep the task safe and report that it was not found instead of falling back to a vague clarification.
- Handle scriptable app tasks as guarded AppleScript automation when possible. Commands may use task metadata, generated source, or compact templates; completion is verified through generic task verification policy instead of requiring visible result text for every app.
- Visualize agent work with a transparent overlay cursor. Normal local-app tasks emit a projected `AgentVisualizationPlan` once the workflow is resolved, then a verified plan from runtime evidence such as dry-run steps, observations, and action traces; visual-only demonstration turns use the same plan shape without live input. Donkey moves the overlay cursor along curved paths and types compact labels next to it while keeping the real mouse untouched.
- Maintain a background agent memory store in Application Support. The store records resolved and missing local-item lookups, prewarms apps plus common user file folders, stores runtime task definitions, keeps metadata such as kind/path/bundle ID/source/task/action, indexes records with SQLite FTS5 plus local vectors, and passes a bounded set of matching hints into the agent harness memory section for classifier and model consideration. See `docs/guides/decision-system.md` for how those hints feed typed model decisions and guarded local-app plans.
- Persist task threads as searchable Core Data conversations with event history, task assets, and per-run runtime coordination for any action work attached to the thread.
- Keep the overlay non-invasive. It may request microphone permission for local waveform capture and voice commands, but it must not capture the screen, synthesize input directly, or require Accessibility permission.

## Technical Guidelines

- `PointerPromptOverlayController` owns AppKit surfaces, placement, hover tracking, focus, keyboard shortcut recognition, dismissal, file-drop routing, and microphone level capture.
- `DonkeyAuthCoordinator` and `DonkeyLoginWindowController` own the Mac sign-in
  gate. App startup should create the overlay controller only after a stored
  Google session exists or a pending sign-in callback validates its state token
  and stores a Better Auth cookie in the app cookie jar.
- SwiftUI rendering lives in `DonkeyUI` and consumes state/contracts from `DonkeyContracts`. It should not perform command parsing, model calls, input execution, screen capture, or microphone capture.
- `PointerPromptOverlayModel` owns product state. Durable task data is persisted through Core Data in Application Support.
- Spawn display state is typed state. The model emits progress, target hints, and current selection; the overlay controller resolves hints against safe visible windows and keeps voice capture on the centered prompt; SwiftUI renders the notch cue, cursors, labels, label-to-editor transition, and selection state.
- Notch geometry comes from the active `NSScreen`, preferring safe-area and auxiliary-top metrics over hardcoded notch sizes. Content must stay out of the physical notch void; displays without a physical notch should use the same top-center composition without reserving unavailable space.
- `PointerPromptNotchLayout` is the shared source for notch surface frames, content frames, corner radii, and notch-safe offsets. `canRenderTextInTopRow` describes whether text can draw in the top row, not whether that row exists.
- The prompt is a compact black composer: single-line text is pill-shaped, multiline text becomes a bounded rounded rectangle, Return submits, Shift-Return inserts a newline, Escape and outside clicks dismiss, and non-input capsule areas can drag the modal.
- The centered composer keeps text and voice modes on the same input surface. Double-Command release opens focused text input, double-Command hold opens the same input with voice active, and typed text promotes the send button while the microphone affordance becomes secondary.
- Voice capture and transcription remain separate. The controller records bounded local audio and publishes levels; transcription uses the Parakeet-only adapter before submitting transcript text through the agent-harness turn path.
- Local item prewarming must run off the main actor. Agent memory is stored in SQLite under Application Support and uses FTS5 plus deterministic local embeddings for retrieval; JSONL is only an explicit export/debug format. Cached local-item hits must still point to an existing path or bundle before they are used as an execution target. Runtime task definitions are loaded from agent memory; Weather, Music, and Preview definitions are benchmark fixtures unless a generated/user-reviewed definition for them is present in memory.
- For scriptable apps, prefer app-native AppleScript task commands before falling back to Accessibility or keyboard input. Bounded screenshots and local UI understanding may supplement observation/verification according to task metadata, but screenshots remain context evidence and do not directly drive input.
- Agent visualization overlays are non-interactive, non-activating panels. They may point, explain, and replay what the agent is doing or would do, but they do not synthesize mouse movement. Live keyboard or Accessibility actions remain separate guarded runtime actions.
- Task actions in the notch, including follow-up submission and pause/resume, must cross the model/controller command boundary with the selected task ID.
- Pointer prompt command handling should emit actionable `com.donkey.app` route/result logs for submitted commands, routing decisions, intent resolution, unsupported requests, unavailable apps, and final task status.

## Verification

Manually verify:

- The notch renders at the top center, respects physical notch safe areas, expands only from visible notch hover, and accepts expanded controls/clicks.
- Double-Command release opens a centered focused text prompt; double-Command hold opens the same prompt with voice active; typed text shows a primary send button and a secondary microphone affordance; unrelated Command use does not activate the overlay.
- Typed, voice, and follow-up submissions create or update durable task threads, answer non-actionable conversation without showing action failure, show action status in the notch when work runs, and preserve per-task pause/resume behavior.
- Typed prompt and notch follow-up submissions show the spawn sequence: notch cue, desktop cursor emergence, direct travel to a known target or fallback holding point, typed submitted-turn label, typed progress/response label, retargeting when the target becomes visible, persistent labels for conversational or attention states, and fade-out only for completed action-only turns.
- Stationary spawn labels clamp to two lines, reveal the full label on hover only when truncated, select the cursor on click, and transition in place into a same-styled inline editor for tasked follow-ups.
- With multiple spawned cursors visible, clicking a cursor selects it; double-Command still opens the centered prompt, and the submitted typed or voice turn routes to the selected/latest cursor's task without opening the inline label editor.
- Open requests for installed apps, files, and folders launch or open the local item; missing local items show a not-found result and log the lookup provider/reason.
- LLM-classified visual-only prompts complete as visualization turns and show the animated cursor with typed labels without moving the real pointer.
- Normal local-app tasks can produce visualization steps for planning, observing, navigating, acting, and verifying. The visualization must not claim completion unless the runtime verification state supports it.
- The prompt supports wrapping, Shift-Return newline insertion, Return submission, Escape dismissal, outside-click dismissal, and dragging from non-input areas.
- File drops on the notch attach to the active or most recent task.

## Source Entry Points

- App orchestration starts in `apps/Donkey/Sources/Donkey/`.
- Typed prompt command handling lives in `apps/Donkey/Sources/Donkey/PointerPromptCommandHandler.swift`.
- Reusable SwiftUI rendering lives in `apps/Donkey/Sources/DonkeyUI/`.
