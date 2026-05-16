# Manual Target Context Capture Master Plan

This file is the active task queue for the manual target context capture milestone.
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

## Remaining Tasks

1. Manually verify the debug entrypoint against real windows.
   - Run `swift run Donkey -- --list-window-candidates`.
   - Run `swift run Donkey -- --manual-capture --window-id <id>` against one normal Mac app window.
   - Run the same flow against iPhone Mirroring when available.
   - Verify an overlapped-window scenario does not produce misleading capture behavior.
   - Verify an Accessibility-trust-missing scenario completes partially with one screenshot artifact and one coordinator permission event.
   - Confirm the run folder contains ordered coordinator events, one screenshot artifact, and an Accessibility artifact only when permission is available.

2. Close out the milestone.
   - Update `docs/guides/minimal-run-coordinator.md` with any findings from live verification.
   - Keep active plans focused on future work only:
     - `plans/18-macos-accessibility.md`
     - `plans/02-capture-and-perception.md`
     - `plans/06-benchmarking.md`
     - `plans/20-off-the-shelf-run-loop.md`
   - Move this file to `plans/done/` after verification and guide cleanup.

## Next Item

Manual verification against real windows.
