# Super Low-Latency Agent Plan

> Archived status: historical context only. This file is not an active implementation queue. Supported behavior lives in `docs/`; future work from this idea needs a fresh active plan created deliberately.

## Objective

Build a desktop AI agent that can play iPhone games through Apple's iPhone Mirroring app with low latency, while keeping the architecture general enough to later control normal desktop software.

iPhone games are the first product focus. Gaming is the latency proof. The larger platform is real-time desktop and mobile-app control from the Mac.

## Archived Plan Status

The active master plan is currently `plans/master-plan.md`. Start with `docs/README.md`, the supported behavior guides, and the active master plan before changing code.

This overview remains archived background. It mixes completed boundaries with broader roadmap ideas, so it should not override the active master plan.

## Near-Term Focus

Become genuinely good at playing iPhone games through iPhone Mirroring.

That means:

- capture the iPhone Mirroring window reliably
- map the mirrored iPhone content rectangle
- perform calibrated taps, swipes, and controller-style actions
- parse game state from screenshots with low latency
- survive real game loops, not just click menus
- measure Mac-side latency separately from mirroring/game response latency
- avoid purchases, ads, account flows, and system dialogs

## Core Architecture

```text
Screen Capture
  -> Off-The-Shelf Vision
  -> Game State Tensor / World State
  -> Fast Controller
  -> Action Engine
  -> Keyboard / Mouse / Controller
```

The slow planner runs beside this loop, not inside it:

```text
World State Snapshots
  -> Slow Planner
  -> Goals / Policies / Recovery Hints
  -> Fast Controller
```

## Latency Rule

The real-time path must never depend on a large LLM or remote VLM call.

Every frame should use local, bounded-cost logic:

- capture only the pixels needed
- run small perception models or classical CV
- keep a compact world state
- choose from cheap action policies
- execute input immediately

## Plan Breakdown

- [manual-target-context-capture-master-plan.md](manual-target-context-capture-master-plan.md): completed manual screenshot, Accessibility tree, and trace artifact capture milestone
- [../master-plan.md](../master-plan.md): current master plan for closing out the off-the-shelf run loop and AI harness milestones
- [../01-latency-budget.md](../01-latency-budget.md): hard timing budget and optimization priorities
- [../02-capture-and-perception.md](../02-capture-and-perception.md): screen capture, visual parsing, and world-state updates
- [../03-fast-controller.md](../03-fast-controller.md): real-time controller design
- [04-slow-planner.md](04-slow-planner.md): completed slow strategy, recovery, and goal-setting layer
- [../05-action-engine.md](../05-action-engine.md): low-latency keyboard, mouse, and controller output
- [../06-benchmarking.md](../06-benchmarking.md): latency measurement, monitoring, traces, and regression gates
- [07-rollout.md](07-rollout.md): phased delivery path from first supported target to production readiness
- [08-dom-parsing.md](08-dom-parsing.md): DOM-driven perception for browser games and web apps
- [09-screenshot-model-inference.md](09-screenshot-model-inference.md): screenshot capture into low-latency vision models
- [10-gaps-to-expand.md](10-gaps-to-expand.md): remaining gaps needed to make the system real
- [11-game-targets.md](11-game-targets.md): recommended games and target sequence
- [12-iphone-mirroring.md](12-iphone-mirroring.md): iPhone Mirroring as a mobile-game target
- [13-subway-surfers-target.md](13-subway-surfers-target.md): concrete Subway Surfers target profile
- [14-synthetic-controller.md](14-synthetic-controller.md): generic synthetic input adapter
- [15-gamepad-controller.md](15-gamepad-controller.md): generic controller/gamepad abstraction for controller-supported games
- [16-iphone-gameplay-roadmap.md](16-iphone-gameplay-roadmap.md): iPhone Mirroring gameplay roadmap
- [17-ios-control-prompt.md](17-ios-control-prompt.md): iOS control prompt and PhoneAgent reference
- [18-macos-accessibility.md](18-macos-accessibility.md): macOS Accessibility tree/action backend
- [../19-ai-harness.md](../19-ai-harness.md): slow-path memory, LLM/VLM connection, model routing, and update plan
- [../20-off-the-shelf-run-loop.md](../20-off-the-shelf-run-loop.md): off-the-shelf perception, deterministic control, and low-latency runtime stack

## System Priorities

1. Latency over generality.
2. iPhone Mirroring competence before broad desktop automation.
3. Local execution over remote calls in the reflex loop.
4. State updates over full-screen re-interpretation.
5. Specialized controllers over universal reasoning.
6. Measurement before optimization claims.
7. Small vision models over large VLMs inside the reflex loop.
8. DOM signals over vision when the target is web-based and the DOM is available.
9. Off-the-shelf components before custom model work.

## First Supported Target

Start with iPhone Mirroring targets that have:

- fast visual feedback
- simple action space
- deterministic or repeatable scenarios
- stable iPhone Mirroring window capture
- no multiplayer anti-cheat risk

Good first candidates:

- tap-only iPhone games
- iPhone puzzle/card games
- simple iPhone endless runners
- Subway Surfers after swipe calibration works
- local iPhone Safari test pages as measurement harnesses

Avoid for the first supported target:

- competitive multiplayer games
- games with anti-cheat
- visually noisy 3D iPhone games
- games requiring multi-touch, gyro, camera, or microphone
- games requiring long strategic memory before basic control works
