# Latency Budget

## Target

The reflex loop should complete in under 100ms end to end.

Stretch target: 30-60ms for simple games.

## Budget

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
- No full-screen expensive inference unless the game requires it.
- No full-resolution model input in the hot path unless measured under budget.
- No unbounded queues between capture, perception, and action.
- Drop stale frames instead of processing late frames.

## Loop Shape

Use a latest-frame-wins design:

```text
Capture thread
  -> overwrites latest frame buffer

Perception thread
  -> reads latest frame
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

## Acceptance Criteria

- Every action trace includes capture timestamp, perception timestamp, decision timestamp, and input timestamp.
- p50 reflex latency is under 60ms for the first demo.
- p95 reflex latency is under 100ms for the first demo.
- Stale-frame actions are counted and visible in metrics.
