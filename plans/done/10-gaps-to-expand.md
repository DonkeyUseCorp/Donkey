# Gaps To Expand

> Archived status: historical context only. This file is not an active implementation queue. Supported behavior lives in `docs/`; future work from this idea needs a fresh active plan created deliberately.

## Goal

Identify the missing plans needed to turn the low-latency agent architecture into a working product.

The current plans cover the main loop, perception options, planner, action engine, and latency measurement. The remaining gaps are mostly about integration, reliability, target selection, safety, and repeatable development.

## Priority 0: Pick A Narrow First Target

The architecture needs one concrete game or app to force decisions.

Open questions:

- Which exact first game or browser target?
- What is the minimum behavior that counts as success?
- What frame rate and reflex latency does that target require?
- Does the target expose DOM, pixels only, or both?
- What input method does it need: keyboard, mouse, or controller?

Deliverable:

- `target-profile.md` with window size, capture region, actions, signals, latency goal, and success criteria.

Why it matters:

Without a target, the system will overgeneralize too early.

## Priority 1: Platform And Backend Selection

Low latency depends heavily on OS capture and input APIs.

Expand into:

- macOS capture backend
- Windows capture backend
- Linux capture backend, if needed
- browser-only capture path, if using a web target
- input backend per OS
- permission setup and failure handling

Deliverable:

- a backend decision matrix with measured capture/input latency on each supported platform

Key risks:

- macOS screen recording/accessibility permissions
- Windows capture API tradeoffs
- browser automation overhead
- OS input APIs that add hidden delay
- focus loss or wrong-window input

## Priority 1: Process And Threading Architecture

The plan says latest-frame-wins, but needs an implementation shape.

Expand into:

- single process vs multi-process
- capture thread ownership
- perception worker ownership
- controller tick loop
- input worker
- shared memory or zero-copy frame passing
- bounded queues
- shutdown behavior
- crash recovery

Deliverable:

- a runtime architecture doc with queue sizes, thread responsibilities, and timing contracts

Rule:

Any queue in the reflex path should have an explicit maximum size, usually 1.

## Priority 1: World-State Schema

Every perception path needs to publish the same kind of state.

Expand into:

- base world-state schema
- source-specific extensions for DOM, model, OCR, and CV
- confidence model
- timestamps and frame ids
- stale-state rules
- planner hint schema
- action command schema

Deliverable:

- versioned JSON or TypeScript schemas for world state, planner hints, and action commands

Why it matters:

The controller should not care whether a signal came from DOM, screenshots, OCR, or a model.

## Priority 1: Safety And Operator Control

The agent controls the computer, so stopping and bounding it is product-critical.

Expand into:

- global kill switch
- release-all-inputs command
- focus guard
- allowed window/app guard
- maximum action rate
- maximum key hold duration
- input dead-man timer
- confidence-based pause
- manual override mode
- visible status indicator

Deliverable:

- safety plan plus test cases for stuck keys, wrong focus, lost window, and low confidence

Rule:

The system should fail still, not fail active.

## Priority 2: Calibration

Mouse movement, capture regions, model crops, and coordinate transforms need calibration.

Expand into:

- screen coordinate system
- window coordinate system
- game viewport coordinate system
- model input coordinate system
- mouse sensitivity calibration
- click target offset calibration
- DPI/scaling handling
- multi-monitor handling

Deliverable:

- calibration flow that maps model/DOM/vision outputs to reliable input coordinates

Key risk:

A model can be accurate but still click the wrong place if coordinate transforms drift.

## Priority 2: Data, Replay, And Labeling

The replay plan needs a data lifecycle.

Expand into:

- frame recording format
- world-state recording format
- action trace format
- retention policy
- privacy filtering
- trace compression
- reproducible replay seeds

Deliverable:

- `data-and-replay.md` with file formats and commands for record, replay, inspect, and compare

Why it matters:

Recorded traces are the fastest way to improve perception and controllers without constantly running the game.

## Priority 2: Evaluation Beyond Latency

Latency is necessary, but the agent also needs to be good.

Expand into:

- task success rate
- survival time
- score improvement
- missed reaction count
- wrong action count
- recovery rate
- false positive/false negative perception metrics
- planner intervention count
- human takeover count

Deliverable:

- evaluation report that combines latency, accuracy, and task outcome

Rule:

A 30ms wrong action is still wrong.

## Priority 2: Target Adapters

Each game/app should live behind a small adapter.

Expand into:

- capture regions
- DOM selectors, if any
- perception config
- action mapping
- controller policies
- success metrics
- recovery rules

Deliverable:

- adapter interface and one first-target adapter

Why it matters:

This is how the project avoids hardcoding one target while still staying latency-first.

## Priority 3: Model Lifecycle

The screenshot-model plan needs a way to choose and improve models.

See [19-ai-harness.md](19-ai-harness.md) for the slow-path model registry, provider connection layer, role-based model routing, and model update workflow. See [20-off-the-shelf-run-loop.md](20-off-the-shelf-run-loop.md) for the hot-path off-the-shelf perception and deterministic control plan.

Expand into:

- candidate model list
- benchmark protocol
- conversion pipeline
- quantization plan
- warmup behavior
- versioning
- rollback
- quality gates
- runtime compatibility checks

Deliverable:

- model selection doc with measured latency and accuracy on recorded traces

Rule:

Do not pick a model from general benchmark numbers. Pick it from target traces.

## Priority 3: Planner Memory And Policy Updates

The slow planner needs boundaries for what it can change.

See [19-ai-harness.md](19-ai-harness.md) for memory layers, memory write rules, planner hint validation, and model-backed policy update boundaries.

Expand into:

- memory format
- goal format
- planner hint validation
- hint expiry
- policy override rules
- conflict resolution between controller and planner
- user instruction priority

Deliverable:

- planner contract doc

Key risk:

A slow planner should not inject unsafe or stale behavior into the real-time controller.

## Priority 3: Privacy, Security, And Compliance

Screen agents can see sensitive information.

Expand into:

- local-only hot path
- screenshot redaction rules
- trace storage location
- trace retention
- opt-in remote planner calls
- secret detection before logging or upload
- multiplayer and anti-cheat exclusion policy

Deliverable:

- privacy and safety policy for captured screens, logs, and remote calls

Rule:

Avoid multiplayer anti-cheat targets. Start with offline or controlled environments.

## Priority 3: Developer Tooling

The project needs commands that make latency work pleasant.

Expand into:

- run live validation
- record trace
- replay trace
- print latency report
- compare against baseline
- visualize action timeline
- inspect latest world state
- test input release
- benchmark parser/model/capture backend

Deliverable:

- CLI plan with command names and expected outputs

Why it matters:

If measurement is annoying, it will not happen often enough.

## Suggested Next Plan Docs

Create these next, in order:

1. `11-target-profile.md`
2. `12-runtime-architecture.md`
3. `13-world-state-schema.md`
4. `14-safety-and-control.md`
5. `15-data-and-replay.md`
6. `16-platform-backends.md`
7. `17-evaluation.md`

## Immediate Next Step

Pick the first target and write the target profile.

The target profile should force concrete answers for:

- pixels vs DOM vs hybrid
- capture region
- action space
- latency budget
- success metric
- safety constraints
- first replay traces
