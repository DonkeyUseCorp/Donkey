# Pointer Prompt Overlay

## Supported Behavior

Donkey supports a floating macOS overlay for conversational task threads and
quick local-app actions:

- Double-tap Command and release to open a centered prompt with keyboard focus.
- Double-tap Command and hold the second press to open the prompt in voice mode.
- Show a top-center notch status surface for task progress, recent tasks, follow-up input, file drops, updates, and per-task pause/resume.
- Keep prompt submissions, voice transcripts, and follow-ups on the same agent-harness path: task-thread routing, context assembly, conversational response, clarification, review, catalog-backed action parsing, task validation, and guarded local-app execution when a turn is actionable.
- Persist task threads as searchable Core Data conversations with event history, task assets, and per-run runtime coordination for any action work attached to the thread.
- Keep the overlay non-invasive. It may request microphone permission for local waveform capture and voice commands, but it must not capture the screen, synthesize input directly, or require Accessibility permission.

## Technical Guidelines

- `PointerPromptOverlayController` owns AppKit surfaces, placement, hover tracking, focus, keyboard shortcut recognition, dismissal, file-drop routing, and microphone level capture.
- SwiftUI rendering lives in `DonkeyUI` and consumes state/contracts from `DonkeyContracts`. It should not perform command parsing, model calls, input execution, screen capture, or microphone capture.
- `PointerPromptOverlayModel` owns product state. Durable task data is persisted through Core Data in Application Support.
- Notch geometry comes from the active `NSScreen`, preferring safe-area and auxiliary-top metrics over hardcoded notch sizes. Content must stay out of the physical notch void; displays without a physical notch should use the same top-center composition without reserving unavailable space.
- `PointerPromptNotchLayout` is the shared source for notch surface frames, content frames, corner radii, and notch-safe offsets. `canRenderTextInTopRow` describes whether text can draw in the top row, not whether that row exists.
- The prompt is a compact black composer: single-line text is pill-shaped, multiline text becomes a bounded rounded rectangle, Return submits, Shift-Return inserts a newline, Escape and outside clicks dismiss, and non-input capsule areas can drag the modal.
- Voice capture and transcription remain separate. The controller records bounded local audio and publishes levels; transcription uses the Parakeet-only adapter before submitting transcript text through the agent-harness turn path.
- Task actions in the notch, including follow-up submission and pause/resume, must cross the model/controller command boundary with the selected task ID.

## Verification

Manually verify:

- The notch renders at the top center, respects physical notch safe areas, expands only from visible notch hover, and accepts expanded controls/clicks.
- Double-Command release opens a centered focused text prompt; double-Command hold opens voice mode; unrelated Command use does not activate the overlay.
- Typed, voice, and follow-up submissions create or update durable task threads, answer non-actionable conversation without showing action failure, show action status in the notch when work runs, and preserve per-task pause/resume behavior.
- The prompt supports wrapping, Shift-Return newline insertion, Return submission, Escape dismissal, outside-click dismissal, and dragging from non-input areas.
- File drops on the notch attach to the active or most recent task.

## Source Entry Points

- App orchestration starts in `apps/Donkey/Sources/Donkey/`.
- Typed prompt command handling lives in `apps/Donkey/Sources/Donkey/PointerPromptCommandHandler.swift`.
- Reusable SwiftUI rendering lives in `apps/Donkey/Sources/DonkeyUI/`.
