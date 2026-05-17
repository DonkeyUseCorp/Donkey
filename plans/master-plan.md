# Fast Local Navigation Agent Master Plan

This is the active task queue. The milestone is focused on fast local navigation: Donkey should turn a short user command into structured intent, navigate the local desktop/app surface quickly, perform guarded local actions, verify the result, and leave the target in the requested state.

Weather lookup is the first simple benchmark scenario for this navigation engine, but it should be represented as app-task knowledge rather than Weather-specific code: when the user says something like "show me the weather for SF", Donkey should resolve the installed app/task definition, open or focus the right app, type/search for San Francisco, verify the result, and present it. The same generic loop should work for many local app use cases where Donkey behaves like an expert user of the app: "play Coldplay" should resolve a media playback task, and "fill out this PDF using this data" should resolve a document form-fill task with document/data context and review gates.

Primary plans:

- `plans/20-off-the-shelf-run-loop.md`
- `plans/19-ai-harness.md`

Supporting plans:

- `plans/01-latency-budget.md`
- `plans/02-capture-and-perception.md`
- `plans/03-fast-controller.md`
- `plans/05-action-engine.md`
- `plans/06-benchmarking.md`
- `plans/22-local-runtime-onboarding.md`

Completed supporting plans:

- `plans/done/04-slow-planner.md`

Supported behavior and engineering guidance belong in `docs/guides/`. This file tracks what is still needed before those active plans can move to `plans/done/`.

## Plan Management Note

Keep this queue grounded in code reality. Move a plan to `plans/done/` only after the relevant behavior is implemented, documented, and verified. If a slice is only scaffolding, dry-run, or provider-specific, call that out here instead of treating it as completion.

## Milestone Goal

Build the first product-shaped loop where Donkey can run a local navigation session with bounded local execution and an optional slow AI sidecar:

```text
user command: "show me the weather for SF"
  -> local intent parse from app-task definitions: weather_lookup(city: "San Francisco")
  -> generic local-app task adapter with Weather as data
  -> launch or focus app
  -> observe app state through Accessibility/window metadata/screenshot fallback
  -> deterministic UI controller
  -> guarded keyboard/mouse/Accessibility action execution
  -> verify Weather is showing San Francisco
  -> latency report and replayable trace

slow AI harness
  -> ambiguous-command parse or recovery only
  -> compact snapshot
  -> model router
  -> structured planner hint
  -> validated hint bus
  -> scoped memory proposal
```

The normal Weather benchmark path should work without a remote model call. A tiny local parser or local slow-model call may help turn the command into structured intent, but navigation, typing, verification, and input must stay local and deterministic.

## Supported Boundary

- Runtime shell: minimal run coordination, ordered events, bounded context assembly, local run artifacts, manual target context capture, first-run local runtime setup UI, manifest-backed runtime download/cache/registration in Application Support, sidecar health recheck, in-memory reflex trace retention, and stage-split latency reports are supported.
- Fast navigation hot path: typed frame/world-state/action contracts, deterministic dry-run loop, bounded target-window frame source, cheap metadata perception, recorded off-the-shelf detector/template/OCR/segmentation evidence projection, screenshot segmentation model-candidate catalog and runner boundary with Ultralytics YOLO26 nano segmentation (`yolo26n-seg.pt`), process-backed YOLO sidecar decoding through `DONKEY_YOLO_SEGMENTER` or app-managed runtime registration, local UI-understanding sidecar decoding through `DONKEY_UI_UNDERSTANDER` or app-managed runtime registration, swappable world-state projection, deterministic controller, loop-integrated metadata-only local-navigation dry-run action selection, optional caller-supplied browser-tab metadata, dry-run action projection, generic local-app task intent contracts, data-driven task definitions, local JSON/JSONL task-definition loading, Ollama-compatible local-model command parsing to validated `TaskIntent`, deterministic parsing as fallback/validator, catalog command resolution, target-app availability checks, local task-context intake, Accessibility control discovery, document form-fill review planning, generic dry-run task adaptation, local-navigation request construction, step projection, guarded keyboard and Accessibility command templates, macOS app launch/focus, guarded macOS keyboard input, guarded `AXPress`/`AXSetValue` backend, pointer-prompt typed command submission, Accessibility visible-text observation when trusted, visible-text verification, component latency reporting, and built-in task definitions for Weather lookup, media playback, and document form-fill are supported. This is not yet a complete live fast-navigation agent: model binaries are user-downloaded after app install rather than bundled, UI-understanding is an adapter boundary rather than a default live observation path, and there is no manually verified live command-to-result Weather trace yet.
- Safety boundary: action-engine command contracts, permission/focus/rate/hold/release guardrails, guarded live-action smoke with injected backends, the narrow macOS keyboard backend for local-app tasks, the narrow macOS Accessibility backend for discovered nodes, and replayable command traces are supported.
- Slow AI boundary: local-model task-intent parsing, Parakeet-only local voice-transcription model routing and process-backed sidecar tracing through `DONKEY_PARAKEET_TRANSCRIBER` or app-managed runtime registration, structured planner hints, validation/expiry/latest-valid selection, loop-adjacent slow-planner trigger/snapshot sidecar, model registry/router, OpenAI Responses and Ollama-compatible planner adapters, provider-backed local/online planner fallback, source-linked memory, bounded semantic memory retrieval contracts, remote-bound redaction hooks, aggregate model-call observability reports, provider-decoded memory proposal handling through the deterministic approver, and replay/eval scaffolding are supported as optional sidecar pieces. NVIDIA Parakeet TDT 0.6B v3 is the selected local voice-transcription default with no Whisper fallback. This is not yet the complete AI harness because the pointer-prompt microphone capture path still needs to feed the Parakeet runtime and live sidecar binaries still need machine-local installation/benchmark evidence.
- Source of truth: detailed supported behavior lives in `docs/guides/minimal-run-coordinator.md`; active unfinished work lives in this plan and its primary/supporting plans.

## Non-Negotiable Rules

- No remote model call, chat LLM call, or general VLM call may be required for a reflex tick.
- Common app commands must prefer deterministic or local intent parsing before remote planning.
- The reflex path uses latest-frame-wins queues; stale frames are dropped and counted.
- The controller consumes typed world state, not raw screenshots.
- The action engine owns OS input; controller policies emit semantic commands only.
- Input starts in dry-run mode. Live input requires policy allowance, focus guard success, and emergency release support.
- Planner output is a validated, expiring hint. It is never direct input.
- Latency claims require monotonic timestamps and a report.
- Full-resolution snapshots, screenshots for AI, and memory writes stay outside the reflex loop.

## Current Reality From Commit Review

Recent commits completed these pieces:

- `9b160f8` and `201e76c`: metadata-only local-navigation dry-run, local-navigation controller contracts, memory/replay scaffolding.
- `0e21088`: OpenAI Responses adapter, planner hint contracts, model registry/router scaffolding.
- `9bebfbb`: slow-planner sidecar trigger/snapshot/hint bus and guarded live-action smoke boundary.
- recent slice: Ollama-compatible local planner adapter, provider-backed local/online slow planner fallback, and explicit slow-planner completion tests.
- current slice: generic local-app task catalog, local-model command parser, deterministic fallback parser, app availability check, and dry-run adapter boundary, with Weather lookup represented as built-in benchmark data.
- `d6e48c9`: archived plans, which was premature for this milestone.

The code now includes the first generic local-app task catalog, local JSON/JSONL task-definition loader, local task context provider, Accessibility control discovery/action planning, document form-fill review planner, Ollama-compatible local-model command parser, deterministic fallback parser, app availability check, dry-run adapter boundary, local-app live runner, macOS launch/focus, keyboard-input and Accessibility-input backends, pointer-prompt typed command wiring, sample app-task definitions across weather/media/document domains, YOLO26 screenshot segmentation model-candidate metadata and process-backed sidecar backend, local UI-understanding sidecar adapter, Parakeet-only local voice-transcription routing and sidecar runtime, shared JSON sidecar runner, first-run local runtime setup UI, manifest-backed runtime download/cache/registration, checksum/signature metadata enforcement, sidecar health recheck, semantic memory retrieval contracts, redaction hooks, aggregate model-call observability, provider-decoded memory proposal handling, and expanded latency reporting. It does not yet publish real Donkey-compatible runtime packages, wire pointer-prompt microphone buffers into Parakeet, make local UI understanding the default live observation fallback, or include a manually verified live command-to-result Weather trace.

## What Should Be Done Next

1. Wire pointer-prompt microphone buffers into the Parakeet-only `LocalVoiceTranscriptionAdapter`, display transcript text, and submit that text through the same validated command-intent path as typed input.
2. Integrate `ProcessBackedLocalUIUnderstandingAdapter` into live observation only when Accessibility/metadata are insufficient and a bounded screenshot/crop artifact is available; its output must remain an observation, never a direct action.
3. Follow `plans/22-local-runtime-onboarding.md` to publish real Donkey-compatible runtime package manifests/files, finalize release-key cryptographic signature verification, keep first-run setup to one app-managed button, add behind-the-scenes repair/remove flows, then run real machine-local sidecar binaries registered by the app-managed installer for YOLO, Parakeet, and UI understanding and record benchmark evidence for weather/media/document tasks.
4. Connect semantic memory retrieval, redaction, aggregate model observability, and provider-decoded memory proposal handling into the live slow-planner/model-call paths, not just contract tests.
5. Keep the current dry-run/guarded-live safety boundary: local or online LLM output can only become validated intent, task definitions, app-knowledge updates, observation summaries, transcripts, memory proposals, or planner hints, never direct input.

## Completion Gates

Do not move the primary/supporting plans back to `plans/done/` until:

- The fast-navigation agent can run from "show me the weather for SF" to a verified Weather app result with no remote model dependency in the execution trace.
- Dry-run traces and guarded live traces explain intent parsing, app launch/focus, observation, selected rule, input/backend calls, verification, and guardrail decisions.
- The task is measurably faster than a documented manual baseline on the same machine, or the report clearly identifies which stage prevents that.
- The broader AI harness uses bounded semantic memory retrieval, remote-bound visual/DOM/context redaction, aggregate model-call observability, and provider-decoded memory proposal approval in live slow-planner paths.
- Voice commands, when enabled, produce local transcript text through the model-routed transcription boundary before command parsing, with no remote dependency.
- The hot loop continues to run when the slow AI harness is disabled or failing.
- p50/p95/p99 reports cover intent parse, app launch/focus, observation, controller decision, action projection, input execution, result verification, and any capture/perception fallback.
- The relevant guide in `docs/guides/` documents the supported behavior and boundaries.
