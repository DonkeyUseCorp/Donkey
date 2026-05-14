# Benchmarking And Monitoring

## Goal

Make latency visible, measurable, and hard to accidentally regress.

No latency claim counts unless it is measured.

The project needs two observability loops:

- local measurement while building and tuning the agent
- continuous monitoring so latency regressions show up over time

## Required Metrics

Per loop:

- capture start timestamp
- capture end timestamp
- perception start timestamp
- perception end timestamp
- model preprocess start timestamp
- model preprocess end timestamp
- model inference start timestamp
- model inference end timestamp
- world-state timestamp
- controller start timestamp
- controller end timestamp
- input command timestamp
- input execution timestamp
- frame age when perception begins
- state age when controller begins
- action age when input executes

Aggregate:

- p50 latency
- p95 latency
- p99 latency
- dropped frames
- stale actions
- planner calls
- planner latency
- controller fallback count
- capture FPS
- perception FPS
- controller tick rate
- queue depth
- CPU usage
- GPU usage, if used
- GPU memory usage, if used
- memory usage
- thermal throttling indicator, when available

## Clock Rules

Use a monotonic high-resolution clock for all internal timing.

Do not use wall-clock time for latency deltas. Wall-clock time can jump due to NTP updates, sleep/wake, or user changes. It is useful for log labels, but not for measuring elapsed time.

Every trace event should include:

- monotonic timestamp for latency math
- wall-clock timestamp for humans
- process id
- thread or worker id
- build/version id
- machine profile

## Measuring End-To-End Latency

There are three levels of latency to measure.

### Internal Software Latency

This is the time from captured frame to input command execution inside the agent.

```text
capture_end -> perception_end -> controller_end -> input_execute
```

This is the easiest latency to measure and should be present from the first supported build.

### Reflex Latency

This is the time from a visual change becoming available to the agent taking an action.

```text
visual_change_on_screen -> captured_frame -> world_state -> action
```

For controlled tests, create a synthetic target that changes color or position on screen, then measure how long the agent takes to respond.

### Physical Loop Latency

This is the true player-feel number:

```text
screen changes -> agent sees it -> input fires -> game responds on screen
```

This may require external measurement, such as a high-FPS camera, OS-level input event tracing, or a game/test app that logs both rendered frame ids and received input events.

## Instrumentation Plan

Add tiny timestamp spans around every hot-path boundary:

```text
capture.start
capture.end
preprocess.start
preprocess.end
model.start
model.end
perception.start
perception.end
state.publish
controller.start
controller.end
action.enqueue
input.execute
```

Each span should be cheap enough to leave on all the time. Avoid synchronous disk writes in the frame loop. Buffer trace events in memory and flush from a background worker.

## Latency Breakdown

Reports should show both total latency and stage latency:

| Metric | Definition |
| --- | --- |
| capture_ms | `capture.end - capture.start` |
| preprocess_ms | `preprocess.end - preprocess.start` |
| model_inference_ms | `model.end - model.start` |
| perception_ms | `perception.end - perception.start` |
| decision_ms | `controller.end - controller.start` |
| input_ms | `input.execute - action.enqueue` |
| software_loop_ms | `input.execute - capture.end` |
| frame_age_ms | `controller.start - capture.end` |
| state_age_ms | `input.execute - state.publish` |

Frame and state age matter because an action can be computed quickly but still be based on stale data.

## Trace Format

Every reflex action should be traceable:

```text
trace_id
frame_id
state_id
action_id
timestamps
latency_breakdown
controller_policy
confidence
planner_hint_id
machine_profile
build_id
```

## Benchmark Modes

1. Capture-only benchmark.
2. Perception-only benchmark from recorded frames.
3. Controller-only benchmark from recorded world states.
4. End-to-end dry run with input disabled.
5. End-to-end live run with input enabled.
6. Synthetic reflex test with a controlled visual stimulus.
7. Long soak test for drift, throttling, and memory growth.

## Monitoring Over Time

Keep a rolling latency history for every serious run.

Track at least:

- latest run
- last good run
- daily best
- daily median
- seven-day trend
- worst regression by stage

Store summaries in a simple machine-readable format:

```text
runs/
  2026-05-12T10-30-00Z/
    summary.json
    trace.jsonl
    config.json
```

The `summary.json` should contain p50, p95, p99, max, FPS, dropped frames, stale actions, and environment details. The `trace.jsonl` can be larger and sampled or compressed as needed.

## Dashboards

Start with a CLI report before building a UI:

```text
Latency report
  total p50/p95/p99
  per-stage p50/p95/p99
  stale actions
  dropped frames
  worst 10 traces
  regression versus baseline
```

Later, add a lightweight local dashboard with:

- live loop latency graph
- per-stage stacked latency
- FPS and queue depth
- stale frame rate
- planner call timeline
- action timeline
- alerts when thresholds are crossed

## Alerts

Alert on symptoms that matter to feel:

- p95 end-to-end latency over 100ms
- p99 end-to-end latency over 150ms
- stale action rate over 2%
- dropped frame rate over 5%
- perception p95 over 50ms
- model inference p95 over target budget
- preprocessing cost over 20% of perception budget
- controller p95 over 20ms
- queue depth above 1 in the reflex loop
- sustained FPS below target

Alerts should include the stage that regressed, the previous baseline, and the worst trace ids.

## Regression Gates

For the first supported target:

- capture p95 under 15ms
- perception p95 under 50ms
- screenshot preprocessing plus model inference p95 under 50ms
- controller p95 under 20ms
- action execution p95 under 5ms
- end-to-end p95 under 100ms

Use both absolute and comparative gates:

- absolute gate: fail when latency exceeds the product target
- comparative gate: warn when a stage gets 10% slower than baseline
- comparative hard fail: fail when a stage gets 25% slower than baseline

Small changes can pass absolute targets while still making the system worse over time. The comparative gate catches that drift.

## Replay Harness

Record frames and world states so performance work can happen without launching the game every time.

Replay should support:

- fixed-speed playback
- maximum-speed playback
- deterministic controller comparison
- output action diffing
- latency comparison against a saved baseline
- frame-age and state-age reporting

## Baselines

Keep explicit baselines for each supported target and machine class.

Example:

```text
baselines/
  macbook-pro-m3/
    simple-2d-game.json
  windows-desktop-gpu/
    simple-2d-game.json
```

Each baseline should record:

- hardware
- OS version
- screen resolution
- game/window settings
- agent config
- capture backend
- model versions
- model runtime
- model precision
- input resolution
- preprocessing pipeline
- measured p50/p95/p99

Do not compare runs across different machines without labeling them. Hardware differences can hide real software regressions.

## First Milestones

1. Add monotonic timestamp helper.
2. Add trace event schema.
3. Record capture and action events.
4. Build a local trace viewer or summary command.
5. Add p50/p95/p99 report.
6. Add a failing threshold check for regressions.
7. Add baseline comparison.
8. Add a 10-minute soak test.
9. Add live console monitoring for active runs.

## Acceptance Criteria

- A single command can print the latest latency report.
- Trace files can explain why an action happened.
- Performance regressions are visible before release time.
- Latency trends can be compared across runs from different days.
- The system can identify whether capture, perception, controller, or input caused a regression.
