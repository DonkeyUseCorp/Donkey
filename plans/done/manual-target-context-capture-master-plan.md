# Manual Target Context Capture Master Plan

> Archived status: historical context only. This file is not an active implementation queue. Supported behavior lives in `docs/`; future work from this idea needs a fresh active plan created deliberately.

This file records the completed manual target context capture milestone.
Supported behavior and engineering guidance belong in `docs/guides/minimal-run-coordinator.md`.

## Completed Tasks

- [x] Add local run artifact storage for `events.jsonl`, `summary.json`, screenshots, and Accessibility artifacts.
- [x] Add visible-window target resolution with focused/frontmost fallback and conservative safety metadata.
- [x] Add snapshot-scoped candidate labels such as `window 1`, mapped to durable `windowID` selection requests.
- [x] Add read-only target-window screenshot artifact capture.
- [x] Add bounded read-only Accessibility snapshot artifact capture.
- [x] Wire manual capture through `RunCoordinator` lifecycle/tool events and persisted trace events.
- [x] Add developer launch arguments for manual verification:
  - `--list-window-candidates`
  - `--manual-capture`
  - `--window-id <UInt32>`
  - `--run-id <safe-id>`
  - `--trace-id <safe-id>`
- [x] Update the supported behavior guide for the completed runtime, capture, Accessibility, and debug-entrypoint slices.
- [x] Manually verify `--list-window-candidates` against current visible Mac windows.
- [x] Manually verify `--manual-capture --window-id <id>` against one normal Mac app window.
- [x] Manually verify an explicitly overlapped-window capture uses the true window capture path without requiring overlap-free bounds.
- [x] Close out the milestone after live verification and guide cleanup.

## Deferred Environment-Dependent Checks

- Run `swift run Donkey -- --manual-capture --window-id <id>` against iPhone Mirroring when an iPhone Mirroring window is available.
  - Blocked on May 16, 2026: no iPhone Mirroring window appeared in the candidate list.
- Verify an Accessibility-trust-missing scenario completes partially with one screenshot artifact and one coordinator permission event when the process is not already Accessibility-trusted.
  - Blocked on May 16, 2026: the current process is Accessibility-trusted; do not reset or revoke macOS privacy permissions without explicit user approval.

## Completion

This milestone is complete. Supported behavior and engineering guidance live in `docs/guides/minimal-run-coordinator.md`; future implementation should continue from the active capture, Accessibility, benchmarking, and off-the-shelf run-loop plans.
