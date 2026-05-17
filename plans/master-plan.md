# Fast Local Navigation Agent Master Plan

This is the active task queue. The milestone is focused on fast local navigation: Donkey should turn a short user command into structured intent, navigate the local desktop/app surface quickly, perform guarded local actions, verify the result, and leave the target in the requested state.

Weather lookup is the first simple benchmark scenario for this navigation engine, but it should be represented as app-task knowledge rather than Weather-specific code: when the user says something like "show me the weather for SF", Donkey should resolve the installed app/task definition, open or focus the right app, type/search for San Francisco, verify the result, and present it. The same generic loop should work for many local app use cases where Donkey behaves like an expert user of the app, using local observation and deterministic control rather than chat reasoning.

Primary plans:

- `plans/20-off-the-shelf-run-loop.md`
- `plans/19-ai-harness.md`

Supporting plans:

- `plans/01-latency-budget.md`
- `plans/02-capture-and-perception.md`
- `plans/03-fast-controller.md`
- `plans/05-action-engine.md`
- `plans/06-benchmarking.md`

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

- Runtime shell: minimal run coordination, ordered events, bounded context assembly, local run artifacts, manual target context capture, in-memory reflex trace retention, and stage-split latency reports are supported.
- Fast navigation hot path: typed frame/world-state/action contracts, deterministic dry-run loop, bounded target-window frame source, cheap metadata perception, recorded off-the-shelf detector/template/OCR/segmentation evidence projection, screenshot segmentation model-candidate catalog with Ultralytics YOLO26 nano segmentation (`yolo26n-seg.pt`), swappable world-state projection, deterministic controller, loop-integrated metadata-only local-navigation dry-run action selection, optional caller-supplied browser-tab metadata, dry-run action projection, generic local-app task intent contracts, data-driven task definitions, Ollama-compatible local-model command parsing to validated `TaskIntent`, deterministic parsing as fallback/validator, catalog command resolution, target-app availability checks, generic dry-run task adaptation, local-navigation request construction, step projection, guarded keyboard command templates, visible-text verification, and built-in Weather benchmark data are supported. This is not yet a live fast-navigation agent: there is no default app launch/focus/type backend, no Accessibility action execution, no live local-model UI-understanding fallback, no live YOLO screenshot segmentation runner, no live voice-transcription adapter, and no verified live command-to-result loop.
- Safety boundary: action-engine command contracts, permission/focus/rate/hold/release guardrails, guarded live-action smoke with an injected backend, and replayable command traces are supported before any default OS input or Accessibility-action backend exists.
- Slow AI boundary: local-model task-intent parsing, local voice-transcription model routing, structured planner hints, validation/expiry/latest-valid selection, loop-adjacent slow-planner trigger/snapshot sidecar, model registry/router, OpenAI Responses and Ollama-compatible planner adapters, provider-backed local/online planner fallback, source-linked memory, and replay/eval scaffolding are supported as optional sidecar pieces. NVIDIA Parakeet TDT 0.6B v3 is the selected local voice-transcription default, with Whisper large-v3-turbo as a local rollback candidate. This is not yet the complete AI harness because semantic retrieval, redaction, aggregate model observability, live microphone transcription, live local visual UI understanding, and provider-decoded memory write proposals remain active.
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

The code now includes the first generic local-app task catalog, Ollama-compatible local-model command parser, deterministic fallback parser, app availability check, dry-run adapter boundary, YOLO26 screenshot segmentation model-candidate metadata, and local voice-transcription model routing. It does not yet include default app launch/focus/type execution, Accessibility action execution, live local-model UI understanding over bounded screenshots/crops, live YOLO screenshot segmentation inference, live microphone transcription, live result verification, semantic memory retrieval, remote-input redaction hooks, aggregate model observability, or provider-decoded memory write proposals.

## What Should Be Done Next

1. Extend the generic local-app task adapter from dry-run projection to guarded-live orchestration: launch/focus the target app, observe app state, find the needed control, enter normalized entities, submit/select, and verify the requested result.
2. Add the default local action backend needed for this narrow first benchmark: app launch/activation plus guarded keyboard typing/clicking or Accessibility actions, with emergency release and focus checks.
3. Add a local model UI-understanding fallback for bounded screenshot/crop context when Accessibility and metadata are insufficient. Prefer this before OCR-specific extraction; OCR can remain a measured optional adapter.
4. Add a measured local screenshot segmentation runner for the YOLO26 candidate only after choosing export/runtime format and crop size; keep it outside live control until p95 latency and mask quality are recorded.
5. Wire pointer-prompt voice input to a local transcription adapter: capture bounded microphone buffers, run the selected local runtime ASR model, emit transcript text, and pass that transcript through the same validated command-intent path as typed input.
6. Add benchmark/reporting evidence for command-to-result latency, local navigation/action latency, verification confidence, visual fallback latency, voice transcription latency/accuracy, and comparison against manual/chat-style workflows.
7. Keep the current dry-run/guarded-live safety boundary: local or online LLM output can only become validated intent, task definitions, app-knowledge updates, observation summaries, transcripts, or planner hints, never direct input.

## Completion Gates

Do not move the primary/supporting plans back to `plans/done/` until:

- The fast-navigation agent can run from "show me the weather for SF" to a verified Weather app result with no remote model dependency in the execution trace.
- Dry-run traces and guarded live traces explain intent parsing, app launch/focus, observation, selected rule, input/backend calls, verification, and guardrail decisions.
- The task is measurably faster than a documented manual baseline on the same machine, or the report clearly identifies which stage prevents that.
- The broader AI harness can retrieve bounded semantic memory, redact remote-bound visual/DOM context, aggregate model-call observability, and route provider-decoded memory proposals through deterministic approval.
- Voice commands, when enabled, produce local transcript text through the model-routed transcription boundary before command parsing, with no remote dependency.
- The hot loop continues to run when the slow AI harness is disabled or failing.
- p50/p95/p99 reports cover intent parse, app launch/focus, observation, controller decision, action projection, input execution, result verification, and any capture/perception fallback.
- The relevant guide in `docs/guides/` documents the supported behavior and boundaries.
