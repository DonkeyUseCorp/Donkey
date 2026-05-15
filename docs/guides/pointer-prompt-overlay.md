# Pointer Prompt Overlay

## Supported Behavior

Donkey supports a floating macOS pointer prompt overlay:

- shows a small inactive agent pointer that follows the user pointer immediately when Donkey starts
- double-tap Command and release to activate and focus the prompt composer at the current pointer location without clicking into the target app
- double-tap Command and hold the second Command press to activate voice input
- shows a native-cursor-sized agent arrowhead and standard macOS-style `Make this so` composer
- shows a dynamic multiline text input, white voice button, and active pointer shadow only while active
- keeps the pointer and composer pinned where activation happened until the user closes or drags the composer
- closes the active composer with a single gray traffic-light-style top-left close button that turns into a close affordance on hover
- supports dragging the active composer from any area outside the input surface
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
- Treat the composer like a compact macOS window containing a single rounded input surface. The input has a fixed width, wraps text into additional lines, and grows the overlay height as text expands.
- Return submits typed text. Shift-Return inserts a deliberate newline.
- The only visible input-adjacent control for now is the white voice button.
- Composer controls should emit typed `PointerPromptIntent` values instead of reaching into runtime, AI, or controller code.
- Pointer colors load from JSON into `PointerPromptTheme`; views must not hard-code product colors.
- The active composer should use a normal system-window corner radius, reserve a small titlebar band with a single gray traffic-light-style top-left close control that shows its close affordance on hover, and keep the input surface and close control interactive while non-input composer surfaces drag the window. Transparent active overlay space must pass clicks through to windows underneath.
- The active composer top edge should align with the highest visible point of the agent pointer.
- The agent pointer should remain close to native cursor size, use the mirrored SVG cursor silhouette from the Noun Project pointer asset, point in the same up-left direction as the native macOS cursor, and keep its tip 48px from the real pointer on an equal x/y diagonal.
- Runtime placement is fixed to `bottomRight`; alternate `PointerPromptPlacement` values are only rendering variants.
- The controller must not clamp visible pointer/composer bounds to `NSScreen.visibleFrame`; cursor positioning is a direct fixed-offset calculation.
- Launch positioning and double-Command focus handling belong in `PointerPromptOverlayController`, not the SwiftUI view.
- Double-Command is the only active shortcut today. Its default lives in `PointerPromptActivationShortcut.doubleCommand` so a future settings layer can supply a different shortcut without rewriting controller event handling.
- Double-Command prompt activation should require two clean Command down/up taps within 450ms. Any intervening key press, mouse press, extra modifier, or overlong Command hold should reset the sequence so normal shortcuts do not summon the composer.
- Holding the second clean Command press for the shortcut's configured hold duration should activate the composer and send the voice input intent instead of waiting for the second release.
- Keep the overlay non-invasive: no capture loop, input execution, Accessibility prompt, or LLM call in this feature.

## Verification

From `apps/Donkey/`:

```sh
swift build
swift run Donkey
```

Launch Donkey and confirm only the small agent pointer appears and follows the main pointer at a fixed bottom-right diagonal offset. Double-tap Command and release to show the composer with keyboard focus, then move the mouse and confirm the active pointer and composer stay pinned. Double-tap Command again but hold the second Command press, and confirm voice input is requested. Type enough text to wrap and confirm the window grows downward while its top edge stays fixed. Press Shift-Return and confirm it inserts a newline; press Return and confirm it submits. Click through transparent overlay space into another desktop window, drag the composer from non-input areas, close it with the top-left close button, and confirm the inactive pointer resumes following the main pointer. Activate near the bottom-right screen edge to confirm the prompt keeps the same fixed offset instead of flipping or clamping. Confirm Command plus another key, Command-click, and a single Command tap do not activate the composer.

To verify color customization, edit `apps/Donkey/Sources/Donkey/Resources/theme.json`, rebuild, and run Donkey.

## Source Entry Points

- App orchestration starts in `apps/Donkey/Sources/Donkey/`.
- Reusable SwiftUI rendering lives in `apps/Donkey/Sources/DonkeyUI/`.
- Historical completion notes live in `plans/done/21-swiftui-pointer-ui.md`.
