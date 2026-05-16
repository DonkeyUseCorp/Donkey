# Donkey

SwiftUI macOS app for the production pointer prompt UI.

This slice renders a compact prompt modal with a live voice waveform. Double-tap Command and release to show and focus the prompt modal near the current pointer location, where the modal stays pinned while live microphone levels drive the waveform. The prompt starts as a wide pill, expands into a rounded rectangle for multiline text, and moves the waveform into a bottom toolbar that blends with the input background without a divider or inactive controls. Clicking outside the modal dismisses it, and a small gray circular x button at the top-right outside corner closes it directly. The overlay opens near the mouse on a 45-degree bottom-right diagonal by default.

It requests microphone permission for local waveform visualization. It does not request Accessibility, Screen Recording, model access, screen capture-loop, or input-control permissions.

Guides:

- [Pointer Prompt Overlay](../../docs/guides/pointer-prompt-overlay.md)
- [Swift MVC Guide](../../docs/guides/swift-mvc.md)

```sh
swift build
swift run Donkey
```

Pointer theme resources are retained for future pointer rendering work in [Sources/Donkey/Resources/theme.json](Sources/Donkey/Resources/theme.json).
