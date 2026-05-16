# Fast Local Navigation Agent Master Plan

This is the active task queue. The milestone is focused on fast local navigation: Donkey should turn a short user command into structured intent, navigate the local desktop/app surface quickly, perform guarded local actions, verify the result, and leave the target in the requested state.

Weather lookup is the first simple benchmark scenario for this navigation engine: when the user says something like "show me the weather for SF", Donkey should open or focus Weather, type/search for San Francisco, verify the result, and present it. The same loop should later generalize to faster game/app navigation where local observation and deterministic control matter more than chat reasoning.

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
  -> local intent parse: weather_lookup(city: "San Francisco")
  -> app/task adapter: Weather
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
- Fast navigation hot path: typed frame/world-state/action contracts, deterministic dry-run loop, bounded target-window frame source, cheap metadata perception, recorded off-the-shelf detector/template/OCR/segmentation evidence projection, swappable world-state projection, deterministic controller, loop-integrated metadata-only local-navigation dry-run action selection, optional caller-supplied browser-tab metadata, and dry-run action projection are supported. This is not yet a live fast-navigation agent: there is no Weather benchmark adapter, no default app launch/focus/type backend, and no verified command-to-result loop.
- Safety boundary: action-engine command contracts, permission/focus/rate/hold/release guardrails, guarded live-action smoke with an injected backend, and replayable command traces are supported before any default OS input or Accessibility-action backend exists.
- Slow AI boundary: structured planner hints, validation/expiry/latest-valid selection, loop-adjacent slow-planner trigger/snapshot sidecar, model registry/router, OpenAI Responses and Ollama-compatible planner adapters, provider-backed local/online planner fallback, source-linked memory, and replay/eval scaffolding are supported as optional sidecar pieces. This is not yet the complete AI harness because semantic retrieval, redaction, aggregate model observability, and provider-decoded memory write proposals remain active.
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
- current working slice: Ollama-compatible local planner adapter, provider-backed local/online slow planner fallback, and explicit slow-planner completion tests.
- `d6e48c9`: archived plans, which was premature for this milestone.

The code does not yet include a Weather benchmark adapter, command-to-intent parsing for navigation tasks, default app launch/focus/type execution, Accessibility action execution, live result verification, local detector/OCR/segmentation/model inference adapters, semantic memory retrieval, remote-input redaction hooks, aggregate model observability, or provider-decoded memory write proposals.

## What Should Be Done Next

1. Add a `weather_lookup` intent contract and parser as the first fast-navigation benchmark, including deterministic aliases such as `SF -> San Francisco`.
2. Add a Weather navigation adapter that can dry-run and then guarded-live: launch/focus Weather, find the search affordance, type the city, submit/select, and verify the displayed location.
3. Add the default local action backend needed for this narrow task: app launch/activation plus guarded keyboard typing/clicking or Accessibility actions, with emergency release and focus checks.
4. Add benchmark/reporting evidence for command-to-result latency, local navigation/action latency, verification confidence, and comparison against manual/chat-style workflows.
5. Keep the current dry-run/guarded-live safety boundary: local or online LLM output can only become validated intent or planner hints, never direct input.

## Completion Gates

Do not move the primary/supporting plans back to `plans/done/` until:

- The fast-navigation agent can run from "show me the weather for SF" to a verified Weather app result with no remote model dependency in the execution trace.
- Dry-run traces and guarded live traces explain intent parsing, app launch/focus, observation, selected rule, input/backend calls, verification, and guardrail decisions.
- The task is measurably faster than a documented manual baseline on the same machine, or the report clearly identifies which stage prevents that.
- The broader AI harness can retrieve bounded semantic memory, redact remote-bound visual/DOM context, aggregate model-call observability, and route provider-decoded memory proposals through deterministic approval.
- The hot loop continues to run when the slow AI harness is disabled or failing.
- p50/p95/p99 reports cover intent parse, app launch/focus, observation, controller decision, action projection, input execution, result verification, and any capture/perception fallback.
- The relevant guide in `docs/guides/` documents the supported behavior and boundaries.
