# Pointer Prompt Overlay

## Supported Behavior

Donkey supports a floating macOS pointer prompt overlay:

- shows a small inactive agent pointer that follows the user pointer immediately when Donkey starts
- command-click anywhere to activate and focus the prompt composer at the current pointer location
- shows a native-cursor-sized agent arrowhead and rounded ChatGPT-style `Make this so` composer
- shows the text input, add context, voice, send controls, and active pointer shadow only while active
- keeps the pointer and composer pinned where activation happened until the user closes or drags the composer
- closes the active composer with a top-left close button and returns to the inactive following pointer
- supports dragging the active composer by its border areas
- lets normal clicks pass through the inactive pointer-only overlay and transparent active overlay space
- follows the user mouse at a fixed 45-degree bottom-right diagonal
- keeps that fixed offset at screen edges instead of flipping or clamping to the visible screen bounds
- renders a shadow underneath the agent pointer when active
- supports user-accessible theme customization through `apps/Donkey/Sources/Donkey/Resources/theme.json`
- keeps runtime and AI harness behavior behind explicit integration boundaries

This is a visual UI capability. It does not capture the screen, send input, call models, or require Accessibility permission.

## Technical Guidelines

- The overlay window is an `NSPanel` owned by `PointerPromptOverlayController`.
- SwiftUI rendering stays in `DonkeyUI`; it receives `PointerPromptState` and `PointerPromptPlacement` from `DonkeyContracts`.
- Product state stays in `PointerPromptOverlayModel`.
- Treat the composer like a ChatGPT input box: one surface can contain typed text, submission, and adjacent controls.
- Composer controls should emit typed `PointerPromptIntent` values instead of reaching into runtime, AI, or controller code.
- Pointer colors load from JSON into `PointerPromptTheme`; views must not hard-code product colors.
- The active composer should use a normal system-window corner radius, expose a top-left close control, and keep controls/content areas interactive while only border regions drag the window. Transparent active overlay space must pass clicks through to windows underneath.
- The active composer top edge should align with the highest visible point of the agent pointer.
- The agent pointer should remain close to native cursor size, use the mirrored SVG cursor silhouette from the Noun Project pointer asset, point in the same up-left direction as the native macOS cursor, and keep its tip 48px from the real pointer on an equal x/y diagonal.
- Runtime placement is fixed to `bottomRight`; alternate `PointerPromptPlacement` values are only rendering variants.
- The controller must not clamp visible pointer/composer bounds to `NSScreen.visibleFrame`; cursor positioning is a direct fixed-offset calculation.
- Launch positioning and command-click focus handling belong in `PointerPromptOverlayController`, not the SwiftUI view.
- Keep the overlay non-invasive: no capture loop, input execution, Accessibility prompt, or LLM call in this feature.

## Verification

From `apps/Donkey/`:

```sh
swift build
swift run Donkey
```

Launch Donkey and confirm only the small agent pointer appears and follows the main pointer at a fixed bottom-right diagonal offset. Command-click anywhere to show the composer with keyboard focus, then move the mouse and confirm the active pointer and composer stay pinned. Click through transparent overlay space into another desktop window, drag the composer from border areas, close it with the top-left close button, and confirm the inactive pointer resumes following the main pointer. Type a message, confirm the send control enables, and activate near the bottom-right screen edge to confirm the prompt keeps the same fixed offset instead of flipping or clamping.

To verify color customization, edit `apps/Donkey/Sources/Donkey/Resources/theme.json`, rebuild, and run Donkey.

## Source Entry Points

- App orchestration starts in `apps/Donkey/Sources/Donkey/`.
- Reusable SwiftUI rendering lives in `apps/Donkey/Sources/DonkeyUI/`.
- Historical completion notes live in `plans/done/21-swiftui-pointer-ui.md`.
