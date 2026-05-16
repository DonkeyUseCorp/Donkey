# Real-Time Run Loop And AI Harness Master Plan

> Archived status: historical context only. This file is not an active implementation queue. Supported behavior lives in `docs/`; future work from this idea needs a fresh active plan created deliberately.

This file was the active task queue for closing out the first local-navigation dry-run, slow-planner sidecar, and guarded live-action smoke milestones. It is now archived.

Historical primary plans:

- `plans/done/20-off-the-shelf-run-loop.md`
- `plans/done/19-ai-harness.md`

Historical supporting plans:

- `plans/done/01-latency-budget.md`
- `plans/done/02-capture-and-perception.md`
- `plans/done/03-fast-controller.md`
- `plans/done/04-slow-planner.md`
- `plans/done/05-action-engine.md`
- `plans/done/06-benchmarking.md`

Supported behavior and engineering guidance belong in `docs/guides/`. There is no active queue in this archived file.

## Plan Management Note

This file is no longer the active queue. New work should start from `docs/README.md`, current guides, and code reality. If a future milestone needs plan coordination, create a fresh active plan deliberately instead of treating this archived roadmap as an implementation list.

## Milestone Goal

Build the first product-shaped loop where Donkey can run a local navigation session with bounded reflex behavior and an optional slow AI sidecar:

```text
local desktop/window/browser context
  -> focused capture / Accessibility / browser-tab metadata
  -> local perception or cheap metadata/template signal
  -> compact world state
  -> deterministic navigation controller
  -> dry-run action trace first, guarded live action later
  -> latency report and replayable trace

slow AI harness
  -> compact snapshot
  -> model router
  -> structured planner hint
  -> validated hint bus
  -> scoped memory proposal
```

The hot path must continue to work with the AI harness disabled.

## Supported Boundary

- Runtime shell: minimal run coordination, ordered events, bounded context assembly, local run artifacts, manual target context capture, in-memory reflex trace retention, and stage-split latency reports are supported.
- Reflex hot path: typed frame/world-state/action contracts, deterministic dry-run loop, bounded target-window frame source, cheap metadata perception, swappable world-state projection, deterministic controller, loop-integrated metadata-only local-navigation dry-run action selection, optional caller-supplied browser-tab metadata, and dry-run action projection are supported. Live OS input is not supported.
- Safety boundary: action-engine command contracts, permission/focus/rate/hold/release guardrails, guarded live-action smoke with an injected backend, and replayable command traces are supported before any default OS input backend exists.
- Slow AI boundary: structured planner hints, validation/expiry/latest-valid selection, loop-adjacent slow-planner trigger/snapshot sidecar, model registry/router, an OpenAI Responses structured-output adapter, source-linked memory, and replay/eval scaffolding are supported as optional sidecar pieces. The hot loop still runs without AI output.
- Source of truth: detailed supported behavior lives in `docs/guides/minimal-run-coordinator.md`; historical implementation details should be found with search in `docs/`, `plans/`, and git history, not duplicated here.

## Non-Negotiable Rules

- No remote model call, chat LLM call, or general VLM call may be required for a reflex tick.
- The reflex path uses latest-frame-wins queues; stale frames are dropped and counted.
- The controller consumes typed world state, not raw screenshots.
- The action engine owns OS input; controller policies emit semantic commands only.
- Input starts in dry-run mode. Live input requires policy allowance, focus guard success, and emergency release support.
- Planner output is a validated, expiring hint. It is never direct input.
- Latency claims require monotonic timestamps and a report.
- Full-resolution snapshots, screenshots for AI, and memory writes stay outside the reflex loop.

## Archived Closeout

The first supported local-navigation runtime slice is documented in `docs/guides/minimal-run-coordinator.md`. The broader roadmap material was moved to `plans/done/` as historical context because its remaining future work is not actionable without a fresh target/product decision.

## What Should Be Done Next

Start with `docs/README.md`. If new work is needed, create a fresh active plan deliberately instead of reviving this archived queue.

## Closeout Outcome

This roadmap is archived because the supported slice is now documented and the remaining ambitions need a fresh target/product decision before they are actionable. The grounded repo state is:

- Fast local navigation can run end to end in dry-run mode.
- Guarded live-action smoke exists only behind dry-run success, latency evidence, policy, focus, and an injected backend.
- Capture, perception, controller, action projection, and input stages use monotonic timing metadata where supported.
- The hot loop works with the AI harness disabled.
- Planner hints, model routing, memory scaffolding, replay/eval scaffolding, and slow-planner sidecar pieces are optional boundaries, not reflex-loop requirements.
- Historical plans are archived in `plans/done/`.
