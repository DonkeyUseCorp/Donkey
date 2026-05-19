# Pointer Prompt Overlay

## Supported Behavior

Donkey supports a floating macOS pointer prompt overlay:

- double-tap Command and release to activate and focus a compact prompt modal centered on the current screen without clicking into the target app
- double-tap Command and hold the second Command press to activate voice input
- shows a notch-anchored black status panel flush with the top center of the current screen
- sizes the notch status panel from `NSScreen.safeAreaInsets` and `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`, with fallback dimensions for non-reporting displays
- keeps status text below the physical notch void while the black panel visually extends the notch
- renders the resting collapsed notch as a slim arrow-only strip beside the physical notch, without adding black padding over the notch void
- starts the resting notch envelope as an arrow lane plus physical notch void plus empty trailing lane, so the arrow remains visible and hover expansion grows from the real collapsed strip
- makes the resting notch envelope height match the detected physical notch height when a notch is present
- only expands from controller-tracked hover over the visible notch surface, not SwiftUI hover over the transparent host panel area
- lets the physical notch void participate in collapsed hover activation while keeping expanded content below the void
- keeps the native status panel collapsed at rest, jumps it to expanded render bounds with AppKit animations disabled before the SwiftUI open spring, and jumps it back after the short non-spring close finishes
- coalesces quick hover enter and exit samples through explicit collapsed, preparing-open, expanded, and closing phases so pending opens and closes do not fight each other
- keeps expanded notch text and controls below the detected physical notch void while allowing the black surface to extend through it, adding vertical surface space instead of squeezing the below-notch content area
- keeps the notch arrow mark pointed up-right at a fixed 45-degree angle
- uses regular-weight notch text; collapsed and expanded notch labels should not render bold text
- expands one notch status surface outward and downward together on hover, with width, height, bottom corner radius, and shadow using one native spring; collapse uses a short ease-out without a spring tail
- matches the `/prototype` notch dimensions while using a native macOS spring envelope: surface `110x28` to `480x280`, interaction container `520x300`, corner radius `14` to `26`, and `spring(response: 0.55, dampingFraction: 0.82)`
- lays out collapsed and expanded notch content inside the animated, clipped surface so content reveals and reflows with the current surface width
- fades collapsed notch content out quickly, then fades expanded content in after the surface has started expanding
- shows an update button in the expanded notch header when Sparkle reports a valid appcast update
- shows a black prompt modal with text input and a white voice waveform while active
- uses a wide pill-shaped prompt for single-line text, then expands to a rounded rectangle when text wraps at the max input width or the user inserts new lines
- places the waveform in a bottom toolbar that blends with the input background when the prompt is expanded
- captures microphone audio while active and renders the waveform from recent live audio levels
- on voice activation, records a bounded local audio buffer, sends it to the Parakeet-only local transcription adapter, displays transcript progress, and submits decoded transcript text through the same command path as typed input
- keeps the prompt modal centered until the user drags or dismisses the modal
- dismisses the active modal when the user clicks outside it
- dismisses the active modal when the user presses Escape while it is visible
- supports dragging the active modal from capsule areas outside the text input
- lets normal clicks pass through the inactive overlay and transparent active overlay space
- opens the prompt input centered on the current screen instead of following the cursor
- dismisses the centered prompt after submission and moves visible progress/result feedback into the notch status panel
- submits typed prompt text through the local-app command pipeline while keeping model parsing, task validation, and live input outside the SwiftUI rendering path

This is a visual, typed-command, and voice-command UI capability. Typed submissions go to the local-app command handler, which loads built-in plus local JSON/JSONL task definitions, prefers local-model task-intent parsing, validates the intent against the app-task catalog, and then runs the guarded local-app live runner. Voice submissions produce local transcript text through the Parakeet-only transcription boundary before entering that same command handler. Review-only document tasks can return a compact review summary such as the number of mapped fields. The overlay itself does not capture the screen, synthesize input, or require Accessibility permission. It does request microphone permission for local waveform capture and voice commands.

## Technical Guidelines

- The overlay uses `NSPanel` surfaces owned by `PointerPromptOverlayController`: a top-center notch status panel and a separate centered prompt input panel.
- Donkey runs with the accessory activation policy, and prompt focus must make the app active, make the panel key, then make the composer text view first responder. A blinking insertion point alone does not mean macOS is sending keyboard events to the panel.
- SwiftUI rendering stays in `DonkeyUI`; it receives `PointerPromptState` and `PointerPromptPlacement` from `DonkeyContracts`.
- Product state stays in `PointerPromptOverlayModel`.
- Treat the active modal as a compact black prompt surface with a text input and embedded waveform. It has no visible close button and no separate voice button.
- Single-line input should render as a full pill. Multiline input should render as a rounded rectangle with non-pill corners and a bottom toolbar matching the input background, containing the waveform without a divider between text and toolbar. The plus and permissions controls may remain available in code for future wiring, but should not render while non-functional.
- The text input should use 16pt light system UI text with ligatures disabled, matching thin `-apple-system` sans-serif web input rendering.
- Text expansion is triggered from a stable pill-width measurement so reaching the single-line edge transitions cleanly without shape flicker. Expanded text uses balanced horizontal padding. Return submits typed text. Shift-Return inserts a deliberate newline.
- Expanded text input grows to a bounded multiline height, then scrolls inside the composer so the waveform toolbar stays attached to the bottom of the prompt instead of being pushed off-screen.
- The controller owns microphone capture and publishes normalized audio levels into product state; SwiftUI only renders the levels it receives.
- The active prompt modal should use a capsule shape and keep transparent active overlay space passing clicks through to windows underneath after it dismisses.
- Pointer drawing and theme code may remain available for future features, but the prompt overlay should not render a visible cursor.
- Runtime placement remains fixed to `bottomRight` for compatibility with the existing view contract; the rendered input panel itself is centered and no longer uses pointer-relative geometry.
- The notch status panel should keep its visual language aligned with the `/prototype` route without exposing agent names or implementation roles: a slim arrow-only resting mark beside the physical notch, a minimal one-line task label when collapsed and active, and a compact current-task panel plus command row when expanded.
- SwiftUI notch rendering should consume `PointerPromptNotchLayout` for derived surface/content frames, corner radii, and notch-safe content offsets instead of duplicating screen-geometry constants in the view.
- Hover activation should be bounded to the visible notch surface using controller-side mouse location checks. The transparent host panel and expanded interaction padding must not trigger expansion or keep the notch expanded by themselves.
- The native status panel should not animate its frame while the SwiftUI notch surface animates. When expansion starts, resize the panel to expanded render bounds with AppKit animations disabled before flipping SwiftUI expansion state; after the short non-spring collapse finishes, resize it back to the resting surface bounds with animations disabled.
- Expanded notch content must treat the physical notch void as unavailable layout space. The surface may cover the void, but text, buttons, and task rows should start below the detected void height while retaining the normal below-notch content height.
- Notch expansion should reveal from the top edge, growing width and height together so the expanded surface feels attached to the physical notch rather than growing from a lower corner. Use a single rendered surface with the prototype dimensions and a native spring for opening width, height, bottom corner radius, and shadow; use a short ease-out on close so there is no spring tail. Keep collapsed and expanded content inside that clipped surface so layout follows the animated width. Delay the expanded content fade-in so the surface leads the content.
- The expanded notch header may show an update button when `PointerPromptUpdateState` is actionable; clicking it should invoke Sparkle's standard update UI outside the SwiftUI view.
- The controller should derive notch geometry from the active `NSScreen`, prefer safe-area and auxiliary-top areas over hardcoded notch sizes, and keep visible status content below the top safe-area inset.
- Launch positioning, notch positioning, and double-Command activation handling belong in `PointerPromptOverlayController`, not the SwiftUI view.
- Double-Command is the prompt activation shortcut through `PointerPromptActivationShortcut.doubleCommand`.
- Double-Command prompt activation should require two clean Command down/up taps within 450ms. Any intervening key press, mouse press, extra modifier, or overlong Command hold should reset the sequence so normal shortcuts do not summon the modal.
- Holding the second clean Command press for the shortcut's configured hold duration should activate the prompt modal and start microphone level capture instead of waiting for the second release.
- Keep the overlay non-invasive: no screen capture loop, input execution, Accessibility prompt, or direct model call in SwiftUI rendering. Submit text to a command handler boundary instead.
- Escape dismissal belongs to the input panel/controller path so the prompt closes even when focus is inside the text input or another active panel child.
- Keep the command handler data-driven. It should resolve task knowledge from the local catalog, including local task definitions in Application Support, before invoking the guarded runtime path.
- Keep voice capture separate from transcription. The overlay publishes bounded local audio buffers to the model layer, and model execution plus command parsing remain outside the SwiftUI view/controller rendering path.

## Verification

From `apps/Donkey/`:

```sh
swift build
swift run Donkey
```

Launch Donkey and confirm the inactive overlay renders as a black notch extension at the top center, with status content below the physical notch area on notched displays. Hover the notch and confirm it expands downward into the current-task panel with a bottom command row, then collapses after the pointer leaves. With Sparkle configured to a local appcast that contains a newer signed update, confirm the expanded header shows an update button and clicking it opens Sparkle's update UI. Double-tap Command and release to confirm the black prompt capsule opens centered on the screen with keyboard focus and no visible close button, grant microphone permission if prompted, then speak or tap near the microphone and confirm the waveform responds to real audio levels. Type enough text to wrap and confirm the prompt changes from a pill into a rounded rectangle and remains centered as it grows. Press Shift-Return and confirm it inserts a newline; press Return and confirm it submits, dismisses the prompt, and shows working/result status in the notch panel. Move the mouse and confirm the active modal stays centered. Double-tap Command again but hold the second Command press, and confirm the same prompt modal appears with voice capture. Press Escape and confirm the active modal dismisses. Click outside the active modal and confirm it dismisses. Reactivate and drag the modal from non-input capsule areas. Confirm Command plus another key, Command-click, and a single Command tap do not activate the modal.

## Source Entry Points

- App orchestration starts in `apps/Donkey/Sources/Donkey/`.
- Typed prompt command handling lives in `apps/Donkey/Sources/Donkey/PointerPromptCommandHandler.swift`.
- Reusable SwiftUI rendering lives in `apps/Donkey/Sources/DonkeyUI/`.
- Historical completion notes live in `plans/done/21-swiftui-pointer-ui.md`.
