# Latency Budget

> Active status: not complete. Current reports support synthetic and dry-run traces, but this plan is not complete until p50/p95/p99 budgets are measured for the first fast-navigation benchmark and compared with a manual baseline.

## Target

The local navigation loop should feel faster than manual navigation. For the first Weather benchmark, measure both command-to-result time and per-step hot-path latency.

Target for the first Weather demo:

- command-to-first-action p95 under 300ms after text submission
- local observation/controller/input step p95 under 100ms
- command-to-verified-result faster than a documented manual baseline on the same machine

For later game/visual targets, the reflex loop should still complete in under 100ms end to end.

Stretch target: 30-60ms for simple games.

## Budget

### Weather Task Budget

| Stage | Baseline Target | Stretch Target |
| --- | ---: | ---: |
| Intent parse | 5-100ms | <20ms deterministic |
| App launch/focus | 100-800ms | 50-300ms when already warm |
| App observation | 5-50ms | 2-15ms |
| Controller decision | 1-20ms | <5ms |
| Input execution | 1-20ms | <5ms |
| Result verification | 10-100ms | 5-30ms |

### Visual Reflex Budget

| Stage | Baseline Target | Stretch Target |
| --- | ---: | ---: |
| Screen capture | 5-15ms | 2-8ms |
| Perception / model inference | 10-50ms | 5-20ms |
| World-state update | 1-5ms | <2ms |
| Action decision | 1-20ms | <5ms |
| Input execution | 1-5ms | <2ms |
| Total | <100ms | 30-60ms |

## Hard Rules

- No large LLM calls in the per-frame loop.
- No remote calls in the per-frame loop.
- No remote call is required for common Weather command parsing or execution.
- No full-screen expensive inference unless the game requires it.
- No full-resolution model input in the hot path unless measured under budget.
- No unbounded queues between capture, perception, and action.
- Drop stale frames instead of processing late frames.

## Loop Shape

Use a latest-frame-wins design:

```text
Observation thread
  -> overwrites latest app/window/task state

Perception thread
  -> reads latest structured observation or latest frame fallback
  -> emits latest world state

Controller thread
  -> reads latest world state
  -> emits immediate action
```

Do not preserve every frame if the system falls behind. A real-time agent should be current, not complete.

## Optimization Order

1. Measure each stage with monotonic timestamps.
2. Remove unnecessary work from the hot path.
3. Shrink the capture region.
4. Use frame differencing to skip perception when nothing relevant changed.
5. Move repeated calculations into cached state.
6. Quantize or replace slow models.
7. Split perception into fast local signals and slower background interpretation.
8. Batch only when it reduces total latency without increasing frame age.

## Latency Risks

- Full-screen capture at high resolution.
- Python-only hot loops for pixel-heavy work.
- Large image copies between processes.
- Image encoding/decoding before inference.
- GPU upload/download overhead.
- Model warmup during the first live loop.
- Remote model calls.
- Synchronous logging in the frame loop.
- Waiting for planner output before acting.
- Input APIs with hidden OS scheduling delays.
- App launch cold-start time.
- Accessibility permission or trust checks.
- Typing into an unverified focused control.

## Acceptance Criteria

- Every action trace includes capture timestamp, perception timestamp, decision timestamp, and input timestamp.
- Every Weather task trace includes intent parse, app launch/focus, observation, decision, input, and verification timestamps.
- p50 local observation/controller/input step latency is under 60ms for the first supported target.
- p95 local observation/controller/input step latency is under 100ms for the first supported target.
- command-to-result time is compared with a manual Weather lookup baseline.
- Stale-frame actions are counted and visible in metrics.
