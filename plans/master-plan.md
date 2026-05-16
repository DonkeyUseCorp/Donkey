# Real-Time Run Loop And AI Harness Master Plan

This file is the active task queue for closing out the off-the-shelf real-time run loop and slow-path AI harness milestones.

Primary plans:

- `plans/20-off-the-shelf-run-loop.md`
- `plans/19-ai-harness.md`

Supporting plans:

- `plans/01-latency-budget.md`
- `plans/02-capture-and-perception.md`
- `plans/03-fast-controller.md`
- `plans/04-slow-planner.md`
- `plans/05-action-engine.md`
- `plans/06-benchmarking.md`

Supported behavior and engineering guidance belong in `docs/guides/`. This master plan should stay small: keep only critical current-boundary context and the active queue.

## Plan Management Note

As work progresses, move only still-actionable items out of the supporting plans and into this master plan so there is one active queue. Do not grow a historical completed-task log here. When a slice becomes supported, update the supported-boundary summary below and the relevant guide in `docs/guides/`; use search across `docs/` and `plans/` for older implementation history.

When a supporting plan has no remaining active work, either move it to `plans/done/` if its acceptance criteria are supported, or leave it active only for clearly named future work that still remains.

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

- Runtime shell: minimal run coordination, ordered events, bounded context assembly, local run artifacts, manual target context capture, in-memory reflex trace retention, and latency reports are supported.
- Reflex hot path: typed frame/world-state/action contracts, deterministic dry-run loop, bounded target-window frame source, cheap metadata perception, deterministic controller, metadata-only local-navigation dry-run action selection, and dry-run action projection are supported. Live OS input is not supported.
- Safety boundary: action-engine command contracts, permission/focus/rate/hold/release guardrails, and replayable command traces are supported before live input.
- Slow AI boundary: structured planner hints, validation/expiry/latest-valid selection, model registry/router, an OpenAI Responses structured-output adapter, source-linked memory, and replay/eval scaffolding are supported as optional sidecar pieces. The hot loop still runs without AI output.
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

## Active Queue

1. Finish fast local navigation dry-run closeout.
   - Wire local-navigation metadata projection into the dry-run reflex loop instead of testing it only as a standalone projector/controller.
   - Add browser-tab metadata where available and keep window metadata as the no-remote-model fallback.
   - Add a swappable local perception adapter for fast inference experiments, but keep navigation working without remote models or chat LLMs.
   - Measure metadata read, crop/resize/normalize if used, inference if used, world-state update, controller decision, and action projection separately with p50/p95/p99 latency.
   - Keep the reflex queue latest-frame/latest-state-wins with queue depth 1, stale-result dropping, and no PNG/JPEG encode/decode in the hot path.

2. Integrate slow planner beside the dry-run loop.
   - Trigger planner calls on scene change, low confidence, repeated failure, goal completion, or user instruction.
   - Build compact snapshots from world state, trace summaries, optional screenshots, and memory.
   - Publish only validated hints to the controller.
   - Prove planner latency does not move p95 reflex latency.

3. Enable guarded live-action smoke only after dry-run closeout.
   - Use fast local navigation as the first target behavior.
   - Run end-to-end dry-run with input disabled and latency report passing.
   - Enable live input only with explicit policy allowance and focus guard.
   - Verify abort and timeout release held input.
   - Record trace evidence for every action.

4. Close out the primary plans.
   - Update supported behavior guides in `docs/guides/`.
   - Move `plans/20-off-the-shelf-run-loop.md` to `plans/done/` when the reflex loop acceptance criteria are supported.
   - Move `plans/19-ai-harness.md` to `plans/done/` when the AI harness acceptance criteria are supported.
   - Move supporting plans to `plans/done/` only if their acceptance criteria are fully satisfied; otherwise update them to describe the remaining future work.
   - Move this master plan to `plans/done/` after both primary plans are closed out.

## What Should Be Done Next

Start with active task 1: finish fast local navigation dry-run closeout.

This is the right next slice because the first metadata-only local-navigation projector and controller can now choose traceable dry-run focus actions with the AI harness disabled. It still needs loop integration, browser-tab metadata where available, and measured local-navigation latency before guarded live input is considered.

## Closeout Criteria

This master plan is complete when:

- The off-the-shelf run loop can run fast local navigation in dry-run mode end to end.
- The first local-navigation behavior can be exercised with guarded live input after dry-run success.
- Capture, perception, controller, action, and input stages are measured with monotonic timestamps.
- p50 and p95 reflex latency are reported for the first supported target.
- The hot loop still works with the AI harness disabled.
- Planner hints are structured, validated, expiring, trace-linked, and optional.
- Memory writes are source-linked, scoped, inspectable, deleteable, and deterministically approved.
- Model routing uses registry roles instead of scattered literal model ids.
- Replay/eval exists for controller traces and model/prompt changes.
- Supported behavior is documented in `docs/guides/`.
- `plans/19-ai-harness.md` and `plans/20-off-the-shelf-run-loop.md` are moved to `plans/done/`.
