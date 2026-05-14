# Swift MVC Guide

## Purpose

Donkey Swift code should keep product state, UI rendering, and AppKit orchestration separate. This keeps the pointer UI easy to change without coupling it to future real-time runtime or AI harness work.

## Pattern

- Model owns observable product state and intent handling.
- View renders state and emits typed intents.
- Controller owns AppKit lifecycle, windows, timers, geometry, and side effects.
- App entry wires the first model and controller, then gets out of the way.

## Technical Guidelines

- Keep SwiftUI views value-like: pass state in, pass typed intent sinks out, and avoid timers, global mouse reads, model providers, or window management inside views.
- Keep models on `@MainActor` when they publish UI state. Models may depend on narrow provider protocols, but not on AppKit windows or timers.
- Keep controllers on `@MainActor` when they touch AppKit. Controllers may read `NSEvent.mouseLocation`, monitor command-click activation, own `NSPanel`, and translate geometry into model state.
- Keep app entry files small. They should define `@main`, delegate adaptation, and little else.
- Prefer target-level separation for reusable contracts and UI: `DonkeyContracts`, `DonkeyUI`, `DonkeyRuntime`, and `DonkeyAI`.
- Keep shared UI state types in `DonkeyContracts`, not in `DonkeyUI`, when models and views both need them.
- Do not let `DonkeyUI` import runtime or AI modules. Future runtime and LLM work must cross through contracts, not view internals.
- Name files after their MVC role when a feature grows past one screen: `FeatureModel.swift`, `FeatureRootView.swift`, `FeatureController.swift`.

## Current Donkey Shape

The pointer overlay follows this split:

- model state covers prompt text, typed input, placement, theme, and typed intents
- views render the composer and pointer from model state
- the controller owns AppKit-only work such as the floating panel, command-click activation, screen bounds, and movement timing
- app entry bootstraps the feature and avoids owning product behavior

## Review Checklist

- A SwiftUI view should not call `NSEvent.mouseLocation`, create an `NSPanel`, start a `Timer`, or import `DonkeyAI`/`DonkeyRuntime`.
- A model should not import `DonkeyUI`; shared display state belongs in `DonkeyContracts`.
- A model should not know about frames, screens, windows, or animation timing.
- A controller should not store business text or decide model-provider behavior beyond presenting existing model state.
- New product behavior should add or extend a guide in `docs/guides/`.
