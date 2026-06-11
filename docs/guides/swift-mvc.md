# Swift MVC Guide

Donkey Swift code keeps product state, UI rendering, and AppKit orchestration
separate, so the pointer UI stays easy to change without coupling it to runtime
or AI harness work. Views render and emit typed intents; models own state;
controllers own AppKit.

**The one rule:** `DonkeyUI` never imports `DonkeyRuntime` or `DonkeyAI`.
Runtime and LLM work crosses through `DonkeyContracts`, never through view
internals. If a view needs runtime data, the data becomes a contract type the
model passes in.

## Pattern

- Model owns observable product state and intent handling.
- View renders state and emits typed intents.
- Controller owns AppKit lifecycle, windows, timers, geometry, and side effects.
- App entry wires the first model and controller, then gets out of the way.

## Technical Guidelines

- Keep SwiftUI views value-like: pass state in, pass typed intent sinks out,
  and avoid timers, global mouse reads, model providers, or window management
  inside views.
- Keep models on `@MainActor` when they publish UI state. Models may depend on
  narrow provider protocols, but not on AppKit windows or timers.
- Keep controllers on `@MainActor` when they touch AppKit. Controllers may read
  screen and event geometry, monitor double-Command activation, own `NSPanel`,
  and translate geometry into model state.
- Keep app entry files small: `@main`, delegate adaptation, and little else.
- Prefer target-level separation for reusable contracts and UI:
  `DonkeyContracts`, `DonkeyUI`, `DonkeyRuntime`, and `DonkeyAI`.
- Keep shared UI state types in `DonkeyContracts`, not in `DonkeyUI`, when
  models and views both need them.
- Name files after their MVC role when a feature grows past one screen:
  `FeatureModel.swift`, `FeatureRootView.swift`, `FeatureController.swift`.

## Current Donkey Shape

The pointer overlay follows this split: model state covers prompt text, typed
input, placement, theme, and typed intents; views render the notch status and
composer from model state; the controller owns AppKit-only work such as the
notch and prompt panels, double-Command activation, screen positioning, and
movement timing; app entry bootstraps the feature without owning product
behavior. See `docs/guides/user-query-overlay.md` for the overlay's full
division of labor.

## Review Checklist

- A SwiftUI view does not call `NSEvent.mouseLocation`, create an `NSPanel`,
  start a `Timer`, or import `DonkeyAI`/`DonkeyRuntime`.
- A model does not import `DonkeyUI`; shared display state belongs in
  `DonkeyContracts`.
- A model does not know about frames, screens, windows, or animation timing.
- A controller does not store business text or decide model-provider behavior
  beyond presenting existing model state.
- New product behavior adds or extends a guide in `docs/guides/`.
