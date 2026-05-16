# Minimal Run Coordinator

## Supported Behavior

Donkey supports a minimal in-memory runtime coordinator for the future off-the-shelf run loop.

The coordinator can:

- accept run sessions with a user goal, target id, runtime profile, and permission policy
- keep only the latest pending live-control session request
- publish ordered `assistant`, `tool`, `lifecycle`, and `reflex` events
- move through explicit lifecycle states for start, pause, resume, completion, abort, timeout, and failure
- deny unsafe input tool calls by default
- mark aborts and timeouts as requiring held-input release
- build bounded planner context from the current session, world-state summary, transcript summary, valid hints, and recent failures

Donkey also supports a local run artifact store for durable trace data. Installed app runs are stored under `~/Library/Application Support/Donkey/Runs/<run-id>/`; tests and development tools may pass an explicit base directory override. Each prepared run creates:

```text
events.jsonl
summary.json
screenshots/
accessibility/
```

The artifact store can append ordered event records, reserve safe screenshot or Accessibility artifact paths, record artifact metadata, and keep `summary.json` current.

Donkey can also resolve visible macOS target-window metadata for the manual capture path. The resolver enumerates on-screen app windows, describes window id, pid, app name, bundle id, title, bounds, focus/frontmost state, iPhone Mirroring hints, and conservative safety metadata. Callers can request a candidate-list snapshot with ephemeral labels such as `window 1` and `window 2`; labels are valid only for that enumeration snapshot and should be converted to the candidate's durable `windowID` for follow-up capture commands. Callers can select an explicit window id or fall back to the focused/frontmost visible window.

Donkey can create a single read-only target-window screenshot artifact after a run folder has been prepared. The screenshot service resolves the target, refuses blocked or review-required safety surfaces, captures the selected window with ScreenCaptureKit's desktop-independent window path, writes PNG bytes under `screenshots/`, and records flattened target/capture metadata in `summary.json`. Overlap-sensitive fallback capture backends must refuse occluded targets instead of silently recording pixels from another window.

Donkey can also create a shallow read-only Accessibility snapshot artifact after a run folder has been prepared. The Accessibility snapshot service resolves the same target-window selection, refuses blocked or review-required safety surfaces, checks Accessibility trust without prompting, writes a bounded JSON tree under `accessibility/` when trusted, and records artifact metadata in `summary.json`. If Accessibility trust is missing, the service appends a clear partial-run tool event to `events.jsonl` and does not create an artifact.

Donkey supports a runtime-level manual target context capture service that wires one read-only capture run through `RunCoordinator`. The service prepares the run folder, starts the session, resolves the target once, passes explicit durable `windowID` selection to screenshot and Accessibility capture services, records coordinator-assigned lifecycle and tool events, persists those events to `events.jsonl`, and completes the run after screenshot success. Missing Accessibility trust is a partial completion: the coordinator records one permission-denied tool event, the screenshot artifact remains, and no Accessibility artifact is created.

The installed executable also supports a developer-only launch-argument entrypoint for manual verification. `--list-window-candidates` prints the current candidate-list labels and durable `windowID` values. `--manual-capture` runs one manual capture, optionally with `--window-id <id>`, `--run-id <safe-id>`, and `--trace-id <safe-id>`, then prints the run folder and artifact paths. These commands are non-interactive and exit before showing the pointer prompt overlay.

This is a coordination, trace, target-metadata, single-screenshot artifact, read-only Accessibility snapshot, and manual capture orchestration foundation only. It does not run perception models, call LLMs, execute OS input, perform Accessibility actions, provide a manual capture UI, or complete live verification against the full target matrix yet.

## Technical Guidelines

- Keep shared event, policy, lifecycle, and context types in `DonkeyContracts`.
- Keep coordinator state and append ordering in `DonkeyRuntime`; UI code should read status through narrow provider boundaries.
- Treat `RunCoordinator` as the owner of lifecycle and event ordering, not as the owner of perception, controller internals, or input backends.
- Treat `LocalRunArtifactStore` as a persistence sink for trace records and artifact metadata. It should not own lifecycle state or decide whether tool calls are allowed.
- Treat macOS window resolution as read-only metadata collection. Safety classifications should be conservative and used by later capture code to refuse or stop on sensitive surfaces.
- Treat target-window screenshot capture as a one-shot artifact write, not a continuous capture loop. ScreenCaptureKit desktop-independent window capture is preferred because overlapping windows do not contaminate the selected target artifact.
- Treat Accessibility snapshot capture as read-only inspection. Keep trees bounded, redact long text values, avoid permission prompts in the capture service, and never perform AX actions from this path.
- Treat manual target context capture as orchestration. `RunCoordinator` owns event order and policy decisions, while screenshot, Accessibility, and artifact-store services remain capture/persistence workers.
- Treat the launch-argument debug entrypoint as developer tooling. It should stay plain text, non-interactive, and should never accept ephemeral labels as capture input.
- Keep mutable installed-app run artifacts in Application Support, not inside the `.app` bundle and not relative to process working directory.
- Keep input actions denied unless a caller provides a policy that explicitly allows them.
- Preserve latest-request-wins behavior for live-control sessions so stale work cannot build up behind the reflex loop.
- Use sampled or summarized reflex events until a measured trace sink exists.

## Verification

From `apps/Donkey/`:

```sh
swift test
```

The runtime tests should cover lifecycle ordering, abort and timeout safety, latest-session queue drops, tool permission denial, event-store ordering, context compaction, artifact path validation, trace folder layout, JSONL event persistence, summary updates, deterministic window resolver behavior through fixture providers, candidate-list label snapshots, screenshot artifact metadata, bounded Accessibility serialization, missing Accessibility trust partial events, unsafe target refusal, overlap-sensitive capture refusal, manual capture event ordering through persisted coordinator events, and debug launch-argument parsing/formatting.

Manual smoke commands:

```sh
swift run Donkey -- --list-window-candidates
swift run Donkey -- --manual-capture --window-id <id>
```

Manual verification on May 16, 2026 confirmed that the list command enumerates current visible Mac windows and that manual capture against a normal Mac app window creates a run folder with 9 ordered coordinator events, one screenshot artifact, and one Accessibility artifact. The verified run targeted a non-frontmost, non-focused Fork window by durable `windowID`.

## Source Entry Points

- Runtime contracts live in `apps/Donkey/Sources/DonkeyContracts/RunLoopContracts.swift`.
- Window target contracts live in `apps/Donkey/Sources/DonkeyContracts/WindowTargetContracts.swift`.
- Runtime coordination lives in `apps/Donkey/Sources/DonkeyRuntime/`.
- macOS window resolution lives in `apps/Donkey/Sources/DonkeyRuntime/MacWindowResolver.swift`.
- Target-window screenshot capture lives in `apps/Donkey/Sources/DonkeyRuntime/WindowScreenshotCaptureService.swift`.
- Accessibility snapshot contracts live in `apps/Donkey/Sources/DonkeyContracts/AccessibilitySnapshotContracts.swift`.
- Read-only Accessibility snapshot capture lives in `apps/Donkey/Sources/DonkeyRuntime/MacAccessibilitySnapshotCaptureService.swift`.
- Manual target context capture orchestration lives in `apps/Donkey/Sources/DonkeyRuntime/ManualTargetContextCaptureService.swift`.
- Manual capture debug command parsing lives in `apps/Donkey/Sources/DonkeyRuntime/ManualCaptureDebugCommand.swift`.
- Local artifact persistence lives in `apps/Donkey/Sources/DonkeyRuntime/LocalRunArtifactStore.swift`.
- The manual capture source plan remains active in `plans/master-plan.md`.
