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

Donkey also supports the first real reflex trace shape for the off-the-shelf run loop. Reflex traces can carry monotonic timing checkpoints for capture, preprocessing, model inference, perception, state publication, controller decision, action enqueue, and input execution. The shared contracts derive stage latency, software-loop latency, frame age, and state age from monotonic timestamps only. `RunCoordinator` can append a `ReflexTraceRecord`, retain it in a bounded in-memory trace store, and publish a matching `reflex` event with compact latency metadata.

Donkey also supports shared hot-loop contracts for deterministic reflex-loop slices. Frames, crops, coordinate spaces, perception signals, compact world states, controller actions, and action results are typed, Codable, Sendable contracts. Coordinate spaces are explicit across screen, window, crop, and normalized target space. Perception signals carry confidence and monotonic source age, and stale signals are marked on world state instead of being silently reused.

Donkey also supports a deterministic dry-run reflex loop skeleton. The loop consumes synthetic, recorded, target-window, or local-navigation metadata frame batches through a latest-frame-wins buffer with queue depth 1, counts dropped frames, converts signals into compact world state through a swappable projector, chooses an inspectable semantic action, projects the action in dry-run mode without OS input, and publishes `ReflexTraceRecord` samples through `RunCoordinator`. This skeleton is for contract validation and replayable tests only; continuous streaming capture and a default OS input backend are not supported yet.

Donkey also supports a bounded target-window frame source for the dry-run hot-loop boundary. The frame source reuses macOS window selection and safety checks, captures selected windows through ScreenCaptureKit's desktop-independent window path, returns `HotLoopFrame` metadata for a caller-provided maximum frame count, and records capture latency and copy cost with monotonic timestamps. This path does not write screenshot artifacts and does not PNG/JPEG encode or decode frames. High-resolution manual screenshot artifacts remain separate from reflex frames.

Donkey also supports the first cheap perception and deterministic controller slice. `CheapPerceptionAdapter` reads deterministic fixture or recorded-frame metadata for template-style targets, emits compact perception signals with confidence and monotonic source age, and marks that raw pixels are not exposed past the perception boundary. `HotLoopWorldStateProjector` converts those signals into compact world state and action affordances. `DeterministicControllerPolicy` selects a semantic `tapTarget` action for fresh high-confidence affordances, otherwise falls back to `wait` or `observe` with explicit rationale and fallback metadata. `DryRunActionProjector` remains side-effect free and records projected dry-run actions without OS input.

Donkey also supports the first off-the-shelf local vision evidence boundary inside the dry-run reflex loop. `RecordedOffTheShelfVisionMetadataCodec` can carry recorded detector, template, OCR, or segmentation observations with crop ids, component ids, model ids, confidence, coordinate spaces, and measured preprocessing/model latency. `OffTheShelfVisionPerceptionAdapter` converts that local evidence into compact `HotLoopPerceptionSignal` values, and `OffTheShelfVisionWorldStateProjector` exposes only typed affordances to the deterministic controller. This is a local perception contract and replay path; it does not yet run a live Core ML, ONNX, OCR, or template matcher over captured pixels.

Donkey also supports the first action-engine guardrail boundary. `ActionEngineGuardrail` accepts typed tap, swipe, key, mouse, controller, and `releaseAll` commands; checks input permission policy, focus guard status, command rate, and maximum hold duration; tracks held-input state; and records replayable command traces. Live input remains disabled by default and requires explicit configuration, an input-allowing policy, a passing focus guard, and an injected input backend. Allowed non-live commands are projected as dry-run traces, live smoke commands record backend execution evidence, denied commands include explicit denial reasons, and `releaseAll` clears held-input state.

Donkey also supports reflex latency reports and a synthetic replay benchmark. `ReflexLatencyReportBuilder` summarizes reflex traces into p50/p95/p99 latency for software-loop, capture, preprocess/crop-normalize, model inference, perception, state update, controller decision, action projection, and input stages, plus capture/perception/controller rates, dropped frames, stale actions, and worst traces. `ReflexReplayBenchmark` can generate deterministic dry-run traces for capture-only, controller-only, or end-to-end dry-run report modes. The installed debug entrypoint can print a CLI-friendly dry-run latency report with `--dry-run-latency-report`.

Donkey also supports the first fast local-navigation dry-run slice end to end through the dry-run reflex loop. `LocalNavigationMetadataFrameSource` can turn macOS window candidate metadata and optional browser-tab metadata supplied by callers into metadata-only hot-loop frames. `LocalNavigationDryRunPerceptionAdapter` and `LocalNavigationDryRunWorldStateProjector` keep the local-navigation path swappable while preserving the no-remote-model fallback. `LocalNavigationControllerPolicy` can choose traceable dry-run semantic actions such as `focusWindow`, `activateCandidate`, `switchTab`, `wait`, or `observe` from typed state. This slice is metadata-only and side-effect free by default; guarded live-action smoke requires an injected backend, and richer visual inference remains future work.

Donkey also supports a guarded live-action smoke boundary for the first local-navigation behavior. `GuardedLiveActionSmokeRunner` requires an end-to-end dry-run result, a latency report with p95 evidence, a non-fallback latest action, explicit input policy allowance, and a passing action-engine focus guard before mapping semantic local-navigation actions to typed action-engine commands. The smoke path records replayable action traces and can execute only through an injected backend; no default OS input backend is enabled.

Donkey also supports slow-path planner hint contracts. `StructuredPlannerHint` carries a goal, policy, priorities, regions of interest, preferred and avoided semantic actions, confidence, expiry, and source trace/frame/state/model-call ids. Planner hints are advisory only; they are validated for unknown actions, unsafe actions, stale state references, low-confidence replacement, and expiry before selection. `PlannerHintSelector` chooses the latest valid hint, and the reflex loop remains able to run without any planner hint.

Donkey also supports the first slow-planner sidecar beside the dry-run reflex loop. `DryRunSlowPlannerSidecar` can trigger on scene changes, low confidence, repeated fallback/failure, already-complete local-navigation goals, or explicit user instruction. It builds compact planner snapshots from the latest world state, action, bounded trace summaries, optional screenshot artifact references, and run memory. Planner work is notified from the dry-run loop after reflex trace publication in a fire-and-forget task, so model latency is not included in reflex p95. `ValidatedPlannerHintBus` publishes only validated hints, and `PlannerHintAwareControllerPolicy` can expose the latest still-valid hint to a controller without letting planner output become direct input.

Donkey also supports the first AI harness model registry and router boundary. `AIModelRegistry` stores model roles, providers, literal model ids, endpoints, capabilities, timeouts, prompt versions, eval status, docs URLs, and rollback ids as registry data. `AIModelRouter` routes slow-path jobs by job type, risk, privacy mode, latency tolerance, capabilities, failed-model history, and allowed providers. Privacy-sensitive planner routes prefer local Ollama-compatible entries when they are available. Literal provider model ids should stay in registry entries, not planner/controller logic.

Donkey also supports the first provider-neutral planner-hint adapter boundary using OpenAI's Responses API. `OpenAIPlannerHintAdapter` reads `OPENAI_API_KEY` from the environment, routes through the model registry, sends a structured-output Responses request with `store: false`, decodes a strict planner-hint JSON response, and records a model-call trace with role, provider, model id, prompt version, schema id, latency, timeout, validation status, and source trace/state ids. Missing credentials, cancellation, timeout, rate limit, invalid output, and provider outage return traceable failures without stopping the reflex loop. Official OpenAI docs were rechecked on May 16, 2026 for the Responses API, `text.format` JSON schema structured outputs, `store: false`, and current model registry default guidance.

Donkey also supports an Ollama-compatible local planner-hint adapter and provider-backed slow planner generator. `OllamaPlannerHintAdapter` sends a local `/api/generate` request with `stream: false` and the same strict planner-hint JSON schema, decodes the local model response into `StructuredPlannerHint`, and records the same model-call trace shape as the OpenAI adapter. `ProviderBackedSlowPlannerHintGenerator` can try local planning first and fall back to the online adapter; either provider can publish only validated hints through the existing slow-planner sidecar and hint bus. Official Ollama docs were checked on May 16, 2026 for the `/api/generate` endpoint, JSON schema `format`, and non-streaming response shape.

Donkey also supports the first memory boundary for slow-path context. Short-term run memory is in-process and bounded; it can retain the current goal, active valid hints, recent world states, recent failures, user instructions, safety stops, and target records for context assembly. Target memory is stored as scoped, source-linked JSONL records under Application Support by default, with tests and tools able to pass an explicit base directory. Model-proposed memory writes go through a deterministic approver before storage. Target and user scoped records require either an expiry timestamp or an explicit durable flag, and records can be listed or deleted by target, run, user, or record id.

Donkey also supports a replay/eval scaffold for model and prompt changes. Planner-hint replay cases summarize recorded traces, decoded hints, validation issues, model-call latency, estimated cost, fallback count, recovery success, and memory-write decisions. `PlannerHintReplayEvaluator` aggregates schema validity, hint acceptance, memory write acceptance and rejection, latency, cost, fallbacks, and recovery success into a promotion report. `AIModelUpdateChecklist` records the model entry, prompt version, `last_verified_at`, docs URLs, eval suite id, rollback model id, and optional report id before model or prompt promotion.

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

This is a coordination, in-memory reflex trace, hot-loop contract, deterministic dry-run skeleton, bounded target-window frame-source, cheap metadata perception, recorded off-the-shelf local vision evidence, deterministic controller, local-navigation dry-run, guarded live-action smoke boundary, slow-planner sidecar, action-engine guardrail, latency-report, planner-hint contract, model-registry/router, OpenAI and Ollama-compatible planner adapters, memory, replay/eval, target-metadata, single-screenshot artifact, read-only Accessibility snapshot, and manual capture orchestration foundation only. It does not run live vision models or OCR over captured pixels, ship a default OS input backend, perform Accessibility actions, provide a manual capture UI, persist high-volume reflex traces to disk, provide continuous streaming capture, or make model calls required for reflex ticks.

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
- Keep hot-loop data flowing through `DonkeyContracts` types. Controllers should consume `HotLoopWorldState`, not raw screenshots, detector tensors, or untyped metadata.
- Keep dry-run action projection side-effect free. It records semantic action intent and trace evidence, but never calls the input capability.
- Keep dry-run world-state projection swappable. Local-navigation metadata, cheap template metadata, and future local inference adapters should share the loop boundary instead of requiring planner or remote-model output.
- Keep reflex frame buffers at queue depth 1. Dropped frames are expected under pressure and should be counted.
- Keep target-window reflex frames bounded by caller-provided frame count until a streaming capture loop exists.
- Keep manual screenshot artifacts and high-resolution planner snapshots separate from reflex frames. The reflex frame source should not encode PNG/JPEG or write screenshot artifacts.
- Keep cheap perception deterministic and compact until real pixel/model adapters exist. Perception may summarize fixture metadata or recorded off-the-shelf detector/template/OCR/segmentation evidence, but controllers must only see typed signals, world state, and action affordances.
- Keep controller fallback explicit. Low confidence, stale signals, missing affordances, and missing signals should produce traceable `wait` or `observe` actions, not silent no-ops.
- Keep every chosen controller action trace-linked with action id, state id, frame id, policy name, confidence, rationale, fallback metadata, and any compact source-evidence metadata needed to explain the rule.
- Keep action-engine commands typed and replayable. Guardrails must run before live input and record permission, focus, rate-limit, hold-duration, release, backend, issued time, backend completion time, and execution status. Live held-input tracking starts only after the backend reports execution.
- Keep live OS input disabled unless a caller explicitly configures live mode, allows input in policy, passes focus guard, and supplies an input backend. The default backend does not synthesize OS events.
- Use monotonic timestamps for latency math. Wall-clock timestamps are for human labels and trace correlation only.
- Use latency reports for any p50/p95/p99 claim. Reports should include dropped frames, stale actions, tick rates, and worst traces.
- Keep local-navigation decisions typed and side-effect free until the guarded live-action slice. Metadata projectors may use window, browser-tab, and Accessibility facts when available, but controllers should emit semantic actions only.
- Treat planner hints as validated, expiring advice. Controllers may use the latest valid hint, but planner output must never become direct input.
- Keep slow planner work beside the reflex loop. Trigger it from compact state, trace, memory, and artifact references; never await model calls from the hot tick before recording the reflex trace.
- Keep model selection in `AIModelRegistry` data. Do not scatter provider model ids through planner code.
- Keep privacy-sensitive Responses API calls configured with `store: false` unless an explicit later policy changes that default.
- Treat provider failures as sidecar failures. Missing credentials, timeout, rate limit, invalid output, or outage should leave the controller running on local state and existing valid hints.
- Keep memory writes source-linked and scoped. Model-proposed memory writes must pass the deterministic approver before storage; target and user records require TTL or explicit durable retention.
- Keep target memory inspectable and deleteable by target, run, user, and record id. Do not use memory JSONL as an opaque cache.
- Promote model or prompt changes only after replay/eval records schema validity, hint acceptance, memory acceptance, latency, cost, fallback count, recovery success, docs URLs, and rollback model id.
- Keep reflex trace retention bounded. The current in-memory store is for recent status and tests, not high-volume replay persistence.
- Use sampled or summarized reflex events until a measured disk trace sink exists.

## Verification

From `apps/Donkey/`:

```sh
swift test
```

The runtime tests should cover lifecycle ordering, abort and timeout safety, latest-session queue drops, tool permission denial, event-store ordering, context compaction, reflex trace latency math, bounded in-memory reflex trace retention, reflex event publication, hot-loop contract Codable round trips, coordinate conversion, stale-signal marking, deterministic dry-run trace publication, queue-depth-1 dropped-frame counting, bounded target-window frame capture, target-frame safety and overlap refusal, target-frame no-artifact/no-encoding metadata, cheap perception signal projection, recorded off-the-shelf vision evidence projection, controller confidence/staleness fallback, controller p95 replay timing under 20ms, local-navigation metadata projection and action selection, local-navigation browser-tab metadata projection, loop-integrated local-navigation dry-run action selection, guarded local-navigation live-smoke gating and trace evidence, abort/timeout release traces, slow-planner trigger/snapshot/validated-hint publication, planner-latency isolation from reflex reports, action-engine permission/focus/rate/hold/release guardrails, latency report percentiles and replay benchmark formatting, planner hint validation/expiry/latest-selection, model registry routing, OpenAI Responses request shaping and failure handling, memory approval/storage/list/delete/context snapshots, replay/eval metric aggregation and model update checklist fields, artifact path validation, trace folder layout, JSONL event persistence, summary updates, deterministic window resolver behavior through fixture providers, candidate-list label snapshots, screenshot artifact metadata, bounded Accessibility serialization, missing Accessibility trust partial events, unsafe target refusal, overlap-sensitive capture refusal, manual capture event ordering through persisted coordinator events, and debug launch-argument parsing/formatting.

Manual smoke commands:

```sh
swift run Donkey -- --list-window-candidates
swift run Donkey -- --manual-capture --window-id <id>
swift run Donkey -- --dry-run-latency-report --frame-count 30
```

Manual verification on May 16, 2026 confirmed that the list command enumerates current visible Mac windows and that manual capture against a normal Mac app window creates a run folder with 9 ordered coordinator events, one screenshot artifact, and one Accessibility artifact. The verified run targeted a non-frontmost, non-focused Fork window by durable `windowID`.

Manual verification also confirmed an overlapped-window case: a Code window overlapped by the higher z-order Codex window was captured by durable `windowID`, used `screenCaptureKitDesktopIndependentWindow`, recorded `overlapStatus=notRequired`, and produced 9 ordered coordinator events with screenshot and Accessibility artifacts.

Remaining live verification is environment-dependent. On May 16, 2026, iPhone Mirroring was not present in the visible-window candidate list, and the current process was already Accessibility-trusted, so the missing-trust partial path was not live-verified to avoid changing macOS privacy permissions.

## Source Entry Points

- Runtime contracts live in `apps/Donkey/Sources/DonkeyContracts/RunLoopContracts.swift`.
- Hot-loop contracts live in `apps/Donkey/Sources/DonkeyContracts/HotLoopContracts.swift`.
- Planner hint contracts live in `apps/Donkey/Sources/DonkeyContracts/PlannerHintContracts.swift`.
- Window target contracts live in `apps/Donkey/Sources/DonkeyContracts/WindowTargetContracts.swift`.
- Runtime coordination lives in `apps/Donkey/Sources/DonkeyRuntime/`.
- The deterministic dry-run reflex skeleton lives in `apps/Donkey/Sources/DonkeyRuntime/DryRunReflexLoop.swift`.
- Bounded target-window reflex frame capture lives in `apps/Donkey/Sources/DonkeyRuntime/TargetWindowFrameSource.swift`.
- Cheap perception, world-state projection, deterministic controller policy, and dry-run action projection live in `apps/Donkey/Sources/DonkeyRuntime/CheapPerceptionAndController.swift`.
- Recorded off-the-shelf detector/template/OCR/segmentation evidence projection lives in `apps/Donkey/Sources/DonkeyRuntime/OffTheShelfVisionPerception.swift`.
- Action-engine guardrails live in `apps/Donkey/Sources/DonkeyRuntime/ActionEngineGuardrails.swift`.
- Guarded live-action smoke lives in `apps/Donkey/Sources/DonkeyRuntime/GuardedLiveActionSmoke.swift`.
- Reflex latency reports and synthetic replay benchmarks live in `apps/Donkey/Sources/DonkeyRuntime/ReflexLatencyReport.swift`.
- Local-navigation contracts live in `apps/Donkey/Sources/DonkeyContracts/LocalNavigationContracts.swift`.
- Local-navigation metadata projection and dry-run action selection live in `apps/Donkey/Sources/DonkeyRuntime/LocalNavigationController.swift`.
- Local-navigation dry-run frame source, loop adapter, world-state projector, and generic controller wrapper live in `apps/Donkey/Sources/DonkeyRuntime/LocalNavigationDryRunLoop.swift`.
- Slow-planner sidecar triggers, snapshots, validated hint bus, and hint-aware controller wrapper live in `apps/Donkey/Sources/DonkeyRuntime/SlowPlannerSidecar.swift`.
- AI model registry and routing live in `apps/Donkey/Sources/DonkeyAI/AIModelRegistry.swift`.
- The OpenAI Responses planner-hint adapter lives in `apps/Donkey/Sources/DonkeyAI/OpenAIPlannerHintAdapter.swift`.
- The Ollama-compatible local planner-hint adapter and provider-backed slow-planner generator live in `apps/Donkey/Sources/DonkeyAI/OllamaPlannerHintAdapter.swift`.
- Memory contracts live in `apps/Donkey/Sources/DonkeyContracts/MemoryContracts.swift`.
- Short-term run memory and target-memory JSONL storage live in `apps/Donkey/Sources/DonkeyRuntime/RunMemoryStore.swift`.
- Replay/eval scaffolding lives in `apps/Donkey/Sources/DonkeyAI/AIReplayEvaluation.swift`.
- Recent reflex trace retention lives in `apps/Donkey/Sources/DonkeyRuntime/InMemoryReflexTraceStore.swift`.
- macOS window resolution lives in `apps/Donkey/Sources/DonkeyRuntime/MacWindowResolver.swift`.
- Target-window screenshot capture lives in `apps/Donkey/Sources/DonkeyRuntime/WindowScreenshotCaptureService.swift`.
- Accessibility snapshot contracts live in `apps/Donkey/Sources/DonkeyContracts/AccessibilitySnapshotContracts.swift`.
- Read-only Accessibility snapshot capture lives in `apps/Donkey/Sources/DonkeyRuntime/MacAccessibilitySnapshotCaptureService.swift`.
- Manual target context capture orchestration lives in `apps/Donkey/Sources/DonkeyRuntime/ManualTargetContextCaptureService.swift`.
- Manual capture debug command parsing lives in `apps/Donkey/Sources/DonkeyRuntime/ManualCaptureDebugCommand.swift`.
- Local artifact persistence lives in `apps/Donkey/Sources/DonkeyRuntime/LocalRunArtifactStore.swift`.
- The manual capture source plan is complete in `plans/done/manual-target-context-capture-master-plan.md`.
