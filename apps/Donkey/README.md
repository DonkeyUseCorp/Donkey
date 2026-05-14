# Donkey

SwiftUI macOS app for the production pointer prompt UI.

This slice renders a floating screenshot-style pointer and ChatGPT-style `Make this so` composer. Command-click anywhere to activate Donkey, show the agent pointer, and focus the prompt input. The composer includes a text area plus room for controls such as add context, voice, and send. The overlay follows the mouse at the bottom right by default, flips around an invisible cursor-centered box near screen edges, and clamps itself inside the visible screen.

It does not request Accessibility, Screen Recording, model access, capture-loop, or input-control permissions.

Guides:

- [Pointer Prompt Overlay](../../docs/guides/pointer-prompt-overlay.md)
- [Swift MVC Guide](../../docs/guides/swift-mvc.md)

```sh
swift build
swift run Donkey
```

Customize the pointer accent color with a six-digit hex value:

```sh
DONKEY_POINTER_ACCENT=0A84FF swift run Donkey
```
