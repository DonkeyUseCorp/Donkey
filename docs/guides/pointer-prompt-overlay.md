# Pointer Prompt Overlay

## Supported Behavior

Donkey supports a floating macOS pointer prompt overlay:

- command-click anywhere to activate the agent pointer and focus the prompt composer
- shows a cursor-style agent pointer and rounded ChatGPT-style `Make this so` composer
- includes a text input area plus room for controls such as add context, voice, and send
- follows the user mouse at bottom right by default while active
- stays fully inside the current screen visible frame
- flips to the left, top, or top-left side when the default position would leave the screen
- animates side changes along an invisible box around the user pointer
- renders a shadow underneath the agent pointer when active
- supports accent-color customization through `DONKEY_POINTER_ACCENT`
- keeps runtime and AI harness behavior behind explicit integration boundaries

This is a visual UI capability. It does not capture the screen, send input, call models, or require Accessibility permission.

## Technical Guidelines

- The overlay window is an `NSPanel` owned by `PointerPromptOverlayController`.
- SwiftUI rendering stays in `DonkeyUI`; it receives `PointerPromptState` and `PointerPromptPlacement` from `DonkeyContracts`.
- Product state stays in `PointerPromptOverlayModel`.
- Treat the composer like a ChatGPT input box: one surface can contain typed text, submission, and adjacent controls.
- Composer controls should emit typed `PointerPromptIntent` values instead of reaching into runtime, AI, or controller code.
- Pointer colors live in `PointerPromptTheme`; views must not hard-code product colors.
- Placement is one of `bottomRight`, `bottomLeft`, `topLeft`, or `topRight`.
- The controller must clamp the final panel frame to `NSScreen.visibleFrame` before applying it.
- Diagonal placement changes should route through a side placement first, so bottom-right overflow can animate to left and then top-left.
- Command-click handling belongs in `PointerPromptOverlayController`, not the SwiftUI view.
- Keep the overlay non-invasive: no capture loop, input execution, Accessibility prompt, or LLM call in this feature.

## Verification

From `apps/Donkey/`:

```sh
swift build
swift run Donkey
```

Command-click anywhere and confirm the composer appears with keyboard focus. Type a message, confirm the send control enables, and move the mouse near the bottom-right screen edge to confirm the prompt moves left, then top-left if needed, without clipping off screen.

To verify color customization:

```sh
DONKEY_POINTER_ACCENT=FF375F swift run Donkey
```

## Source Entry Points

- App orchestration starts in `apps/Donkey/Sources/Donkey/`.
- Reusable SwiftUI rendering lives in `apps/Donkey/Sources/DonkeyUI/`.
- Historical completion notes live in `plans/done/21-swiftui-pointer-ui.md`.
