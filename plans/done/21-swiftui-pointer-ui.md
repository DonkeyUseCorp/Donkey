# SwiftUI Pointer UI

> Archived status: historical context only. This file is not an active implementation queue. Supported behavior lives in `docs/`; future work from this idea needs a fresh active plan created deliberately.

## Goal

Add the production macOS SwiftUI pointer prompt UI while keeping the future real-time run loop and AI harness decoupled behind explicit integration boundaries.

## Completed Shape

- SwiftPM macOS app lives under `apps/Donkey/`.
- UI renders the supported pointer prompt as a floating SwiftUI/AppKit overlay.
- Command-click anywhere activates the agent pointer and focuses the prompt input.
- The prompt follows the mouse at bottom right by default, flips to the opposite side near screen edges, and stays clamped inside the visible screen.
- The active pointer renders with a shadow and supports theme-color customization.
- Contracts, UI, runtime boundary, AI boundary, and app entrypoint are separate Swift targets.
- Runtime boundary references `plans/done/20-off-the-shelf-run-loop.md`.
- AI boundary references `plans/done/19-ai-harness.md`.
- No Screen Recording, Accessibility, model calls, capture loop, or input execution is included in this slice.

## Acceptance

- `swift build` succeeds from `apps/Donkey/`.
- No Swift test target is included because the local Command Line Tools install does not provide `XCTest` or Swift `Testing`.
- `swift run Donkey` launches the Donkey pointer UI.

## Guide

- Product support guide: `docs/guides/pointer-prompt-overlay.md`
