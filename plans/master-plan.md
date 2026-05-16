# Manual Target Context Capture Master Plan

## Goal

Build the first read-only data capture milestone for Donkey runs.

One manual command or UI action should create a run session, select any visible target window, capture a screenshot, dump a shallow macOS Accessibility tree, write trace artifacts, and publish ordered runtime events.

This should prove the data path before continuous capture, perception models, or synthetic input are added.

## Master Plan Role

Use this document as the current active master plan for the next sequence of work.

It coordinates the order of plan edits and implementation slices needed to move Donkey from a runtime coordinator shell into real target-window context capture. Start here before editing the older active plans.

Edit sequence:

1. Keep this plan as the implementation driver until manual target context capture is supported.
2. Update [18-macos-accessibility.md](18-macos-accessibility.md) only for Accessibility details that are still future-facing after read-only AX snapshots exist.
3. Update [02-capture-and-perception.md](02-capture-and-perception.md) only for capture/perception boundaries that remain after manual screenshots are supported.
4. Update [06-benchmarking.md](06-benchmarking.md) only for trace/artifact measurement rules that remain broader than this milestone.
5. Update [20-off-the-shelf-run-loop.md](20-off-the-shelf-run-loop.md) only for the larger runtime/perception loop that remains after the minimal coordinator and manual capture pieces are documented.
6. When this milestone is implemented, write or update the supported guide in `docs/guides/`, then move this plan to `plans/done/`.

Do not spread implementation instructions across multiple active plans while this one is still open. Use linked plans for background and cleanup targets, not as competing sources of truth.

## Related Plans And Guides

- [20-off-the-shelf-run-loop.md](20-off-the-shelf-run-loop.md): runtime shell, event streams, session lifecycle, and coordinator boundary
- [18-macos-accessibility.md](18-macos-accessibility.md): Accessibility tree/action backend and iPhone Mirroring window guard
- [02-capture-and-perception.md](02-capture-and-perception.md): screenshot capture and world-state direction
- [06-benchmarking.md](06-benchmarking.md): trace events, timestamps, and run artifact shape
- [12-iphone-mirroring.md](12-iphone-mirroring.md): first target surface for mobile-game capture
- [../docs/guides/minimal-run-coordinator.md](../docs/guides/minimal-run-coordinator.md): supported run coordinator behavior

## Scope

Build a manual, read-only capture flow:

```text
prompt / debug command
  -> RunSession
  -> target window resolver
  -> screenshot capture
  -> Accessibility tree snapshot
  -> trace artifact write
  -> RunCoordinator tool/lifecycle events
  -> compact context summary
```

In scope:

- enumeration and selection of any visible macOS window
- active, focused, or explicitly selected window metadata
- iPhone Mirroring as one supported target option, not a special-only path
- screenshot artifact metadata and PNG output
- shallow Accessibility tree snapshot with roles, labels/titles, values, frames, pid, and window metadata
- local trace folder for one run, stored under Application Support by default
- ordered runtime events for capture and persistence
- privacy-oriented redaction boundaries for sensitive windows

Out of scope:

- continuous frame capture
- OCR, object detection, SAM, or model inference
- synthetic input or Accessibility actions
- remote model calls
- full desktop recording
- hot-loop performance optimization

## Implementation Plan

### Runtime And Permission Integration

- Add a capture-facing service in `DonkeyRuntime` that works with `RunCoordinator`.
- Extend the current tool capability policy only as needed for read-only capture:
  - screenshot/window capture
  - Accessibility tree read
  - trace persistence
- Keep input/action capabilities denied by default.
- Emit `tool` events for target resolution, screenshot capture, Accessibility snapshot, and artifact persistence.
- Emit `lifecycle` events for manual capture start, completion, abort, timeout, and failure.

### Target Window Resolution

Supported as the second vertical slice. `MacWindowResolver` enumerates visible on-screen macOS app windows, normalizes window metadata, returns candidate-list snapshots with ephemeral labels for manual/debug selection, supports explicit selection by window id, falls back to the focused/frontmost candidate, marks iPhone Mirroring as a normal candidate with a hint, and attaches conservative safety metadata.

Current boundaries:

- Window candidate numbering is not durable. Candidate-list snapshots map short labels like "window 1" to the candidate's macOS `windowID` only for the current enumeration; follow-up commands should carry the durable `windowID`.
- Selection by pid/title tuple is still future-facing. Current deterministic selection is explicit window id or focused/frontmost fallback.
- Safety classification is metadata-only. Later capture orchestration must refuse or safety-stop blocked/review-required targets before writing screenshots.
- Overlap is not solved by metadata alone. Screenshot capture must avoid accidentally recording another window that visually covers the selected target.

### Screenshot Capture

Supported as the third vertical slice. `WindowScreenshotCaptureService` creates one read-only screenshot artifact after a run folder has been prepared. It resolves a target from explicit `windowID` or focused/frontmost fallback, refuses blocked or review-required safety surfaces, captures the selected window with ScreenCaptureKit desktop-independent window capture, writes PNG bytes through the local artifact store, and records flattened target/capture metadata.

Screenshots are stored under the prepared run folder:

```text
<run-folder>/screenshots/<artifact-id>.png
```

Current boundaries:

- The production path uses true window capture, so overlapping windows do not contaminate the artifact.
- Bounds-crop fallback behavior is represented by an overlap-sensitive capturer abstraction and tests, but no production bounds-crop backend is installed.
- Screen Recording/TCC denial surfaces as a capture failure and must not create an artifact record.
- The service does not publish `RunCoordinator` events yet.

### Accessibility Tree Snapshot

Supported as the fourth vertical slice. `MacAccessibilitySnapshotCaptureService` creates one read-only Accessibility snapshot artifact after a run folder has been prepared. It resolves a target from explicit `windowID` or focused/frontmost fallback, refuses blocked or review-required safety surfaces, checks Accessibility trust without prompting, captures a bounded AX tree when trusted, writes JSON through the local artifact store, records target/snapshot metadata, and appends a partial-run tool event when trust is missing.

AX snapshots are stored under the prepared run folder:

```text
<run-folder>/accessibility/<artifact-id>.json
```

Current boundaries:

- The snapshot path is read-only. It records available AX action names but never performs Accessibility actions.
- Missing Accessibility trust creates an `events.jsonl` partial-run event and no artifact; the service does not open System Settings or request trust.
- AX window matching is best effort by pid, title, focus, and frame metadata. Selection remains durable by `windowID` at the resolver/capture boundary.
- Trees are bounded by depth, children per node, total nodes, and text length. Long text values are summarized with redaction markers.
- The service does not publish ordered `RunCoordinator` events yet.

### Trace Artifact Store

Supported as the first vertical slice. `LocalRunArtifactStore` prepares durable run folders, appends JSONL event records, reserves safe artifact paths, records artifact metadata, and updates summaries.

Installed Donkey stores runs under:

```text
~/Library/Application Support/Donkey/Runs/<run-id>/
```

Tests and development tools may pass an explicit base directory override. Each run folder contains:

```text
events.jsonl
summary.json
screenshots/
accessibility/
```

- Keep the artifact store simple and local for this milestone. It can become async or buffered after coordinator capture events are wired to disk.

### Context Assembly

- Feed compact artifact references into context assembly:
  - screenshot artifact ids and target metadata
  - Accessibility tree summary
  - recent capture failures
  - run goal and target id
- Do not pass raw screenshots or full AX trees to an LLM yet.

## Acceptance Criteria

- A manual command or prompt action creates a run session and one trace folder.
- The trace folder contains `events.jsonl`, `summary.json`, one screenshot artifact, and one Accessibility snapshot when permission is available.
- The capture flow records ordered `tool` and `lifecycle` events through `RunCoordinator`.
- Screenshot capture is target/window scoped by default.
- Overlapping windows do not silently produce misleading target screenshots. The capture path either uses true window capture or records/refuses an overlap-sensitive bounds crop when the target is occluded.
- Accessibility tree capture is shallow, bounded, and serializable.
- Missing Accessibility permission produces a clear event and a partial run summary instead of crashing.
- Input and Accessibility actions remain disabled.
- Sensitive/system/payment/login windows are refused or marked as safety stops.
- Unit tests cover metadata serialization, target selection rules, run artifact path generation, artifact summary updates, bounded AX tree serialization, overlap/occlusion safety behavior, and policy denial for input.
- Manual verification works against at least two different windows, such as iPhone Mirroring and a normal Mac app window.

## Handoff Notes For The Next LLM

- Before implementing, re-read `docs/README.md`, `docs/guides/minimal-run-coordinator.md`, `plans/18-macos-accessibility.md`, and `plans/20-off-the-shelf-run-loop.md`.
- Keep this plan active while manual capture is incomplete.
- When this milestone is complete, create or update a supported guide in `docs/guides/` for data capture and Accessibility snapshots.
- After the guide exists and tests/manual verification pass, move this plan to `plans/done/`.
- Clean up overlapping completed details in active plans:
  - keep `plans/20-off-the-shelf-run-loop.md` focused on future off-the-shelf perception and runtime direction
  - avoid duplicating the already-supported minimal coordinator behavior from `docs/guides/minimal-run-coordinator.md`
  - keep `plans/18-macos-accessibility.md` focused on future AX actions/window guards once read-only AX capture is documented
- Prefer shrinking active `plans/` when a capability becomes supported. Completed implementation facts should live in `docs/guides/`, not in long active plan sections.

## What Should Be Done Next

Continue the read-only vertical slice from the completed local artifact writer, window resolver, candidate-list API, screenshot artifact service, and Accessibility snapshot service:

1. Wire the manual capture flow through `RunCoordinator` events.
   - Emit ordered lifecycle/tool events for target resolution, screenshot capture, AX snapshot, artifact persistence, completion, and failure paths.
2. Add integration tests and manual verification.
   - Cover artifact metadata, bounded AX serialization, policy denial for input, and partial summaries.
   - Manually verify against iPhone Mirroring and at least one other visible Mac app window, including an overlapped-window scenario.
