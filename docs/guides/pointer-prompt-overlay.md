# Pointer Prompt Overlay

## Supported Behavior

Donkey supports a floating macOS pointer prompt overlay:

- double-tap Command and release to activate and focus a compact prompt modal at the current pointer location without clicking into the target app
- double-tap Command and hold the second Command press to activate voice input
- shows a black prompt modal with text input and a white voice waveform while active
- uses a wide pill-shaped prompt for single-line text, then expands to a rounded rectangle when text wraps at the max input width or the user inserts new lines
- places the waveform in a bottom toolbar that blends with the input background when the prompt is expanded
- captures microphone audio while active and renders the waveform from recent live audio levels
- keeps the prompt modal pinned where activation happened until the user drags, dismisses, or closes the modal
- dismisses the active modal when the user clicks outside it
- closes the active modal with a small high-contrast circular x button outside the prompt surface at the top-right corner
- supports dragging the active modal from capsule areas outside the text input
- lets normal clicks pass through the inactive overlay and transparent active overlay space
- opens near the user mouse at a fixed 45-degree bottom-right diagonal
- keeps that fixed offset at screen edges instead of flipping or clamping to the visible screen bounds
- submits typed prompt text through the local-app command pipeline while keeping model parsing, task validation, and live input outside the SwiftUI rendering path

This is a visual, typed-command, and microphone-level UI capability. Typed submissions go to the local-app command handler, which prefers local-model task-intent parsing, validates the intent against the app-task catalog, and then runs the guarded local-app live runner. The overlay itself does not capture the screen, synthesize input, transcribe speech, or require Accessibility permission. It does request microphone permission so the waveform can reflect live local audio levels. The AI harness has a local voice-transcription model route, but the overlay has not yet wired microphone buffers into a speech-to-text adapter.

## Technical Guidelines

- The overlay window is an `NSPanel` owned by `PointerPromptOverlayController`.
- Donkey runs with the accessory activation policy, and prompt focus must make the app active, make the panel key, then make the composer text view first responder. A blinking insertion point alone does not mean macOS is sending keyboard events to the panel.
- SwiftUI rendering stays in `DonkeyUI`; it receives `PointerPromptState` and `PointerPromptPlacement` from `DonkeyContracts`.
- Product state stays in `PointerPromptOverlayModel`.
- Treat the active modal as a compact black prompt surface with a text input, embedded waveform, and a small high-contrast circular x button perched outside the surface at the top-right corner. It has no separate voice button.
- Single-line input should render as a full pill. Multiline input should render as a rounded rectangle with non-pill corners and a bottom toolbar matching the input background, containing the waveform without a divider between text and toolbar. The plus and permissions controls may remain available in code for future wiring, but should not render while non-functional.
- The text input should use 16pt light system UI text with ligatures disabled, matching thin `-apple-system` sans-serif web input rendering.
- Text expansion is triggered from a stable pill-width measurement so reaching the single-line edge transitions cleanly without shape flicker. Expanded text uses balanced horizontal padding. Return submits typed text. Shift-Return inserts a deliberate newline.
- Expanded text input grows to a bounded multiline height, then scrolls inside the composer so the waveform toolbar stays attached to the bottom of the prompt instead of being pushed off-screen.
- The controller owns microphone capture and publishes normalized audio levels into product state; SwiftUI only renders the levels it receives.
- The active prompt modal should use a capsule shape and keep transparent active overlay space passing clicks through to windows underneath after it dismisses.
- Agent pointer drawing and theme code may remain available for future features, but the prompt overlay should not render a visible cursor.
- The prompt should keep its retained fixed offset geometry from the real pointer on an equal x/y diagonal.
- Runtime placement is fixed to `bottomRight`; alternate `PointerPromptPlacement` values are only rendering variants.
- The controller must not clamp visible modal bounds to `NSScreen.visibleFrame`; cursor-relative positioning is a direct fixed-offset calculation.
- Launch positioning and double-Command activation handling belong in `PointerPromptOverlayController`, not the SwiftUI view.
- Double-Command is the only active shortcut today. Its default lives in `PointerPromptActivationShortcut.doubleCommand` so a future settings layer can supply a different shortcut without rewriting controller event handling.
- Double-Command prompt activation should require two clean Command down/up taps within 450ms. Any intervening key press, mouse press, extra modifier, or overlong Command hold should reset the sequence so normal shortcuts do not summon the modal.
- Holding the second clean Command press for the shortcut's configured hold duration should activate the prompt modal and start microphone level capture instead of waiting for the second release.
- Keep the overlay non-invasive: no screen capture loop, input execution, Accessibility prompt, or direct model call in SwiftUI rendering. Submit text to a command handler boundary instead.
- Keep voice capture separate from transcription. The overlay may publish bounded local audio buffers to a future transcription adapter, but model execution and command parsing should remain outside the SwiftUI view/controller rendering path.

## Verification

From `apps/Donkey/`:

```sh
swift build
swift run Donkey
```

Launch Donkey and confirm the inactive overlay does not render a visible cursor. Double-tap Command and release to show the black prompt capsule with keyboard focus, grant microphone permission if prompted, then speak or tap near the microphone and confirm the waveform responds to real audio levels. Type enough text to wrap and confirm the prompt changes from a pill into a rounded rectangle, grows downward while its top edge stays fixed, and moves the waveform into a blended bottom toolbar with no divider between the toolbar and text input. Press Shift-Return and confirm it inserts a newline; press Return and confirm it submits. Move the mouse and confirm the active modal stays pinned. Double-tap Command again but hold the second Command press, and confirm the same prompt modal appears. Click outside the active modal and confirm it dismisses. Reactivate, click the high-contrast rounded x button outside the capsule, and confirm it closes and remains visible over light and dark app backgrounds. Drag the modal from non-input capsule areas. Activate near the bottom-right screen edge to confirm the prompt keeps the same fixed offset instead of flipping or clamping. Confirm Command plus another key, Command-click, and a single Command tap do not activate the modal.

## Source Entry Points

- App orchestration starts in `apps/Donkey/Sources/Donkey/`.
- Reusable SwiftUI rendering lives in `apps/Donkey/Sources/DonkeyUI/`.
- Historical completion notes live in `plans/done/21-swiftui-pointer-ui.md`.
