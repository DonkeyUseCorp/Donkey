# Rollout Plan

## Phase 0: Prototype Target

Pick the first iPhone Mirroring target and define the minimum viable agent behavior.

Deliverables:

- iPhone game or iPhone Safari harness choice
- iPhone Mirroring window capture working
- iPhone content rectangle detection
- latency measurement harness
- first world-state schema
- Mac input/accessibility permission path documented

Success:

- capture and action can run independently
- no planner is required

## Phase 1: iPhone Mirroring Control Loop

Build the complete low-latency loop for one narrow iPhone game behavior.

Deliverables:

- iPhone Mirroring capture crop
- synthetic tap/swipe controller
- coordinate calibration
- simple perception
- fast controller
- action engine
- trace logging

Success:

- agent reacts to a visible signal in under 100ms p95
- stale frames are dropped
- input can be stopped safely
- taps/swipes are blocked when the wrong window has focus

## Phase 2: Competent iPhone Game Demo

Expand from one reaction to a short playable loop.

Deliverables:

- multiple perception signals
- policy selector
- confidence-aware fallback
- basic replay harness
- latency report command
- game-specific adapter for the first iPhone game

Success:

- agent plays a repeatable scenario for 1-3 minutes
- p95 reflex latency remains under 100ms
- failures are diagnosable from traces

## Phase 3: Slow Planner

Add high-level strategy without touching the reflex latency path.

Deliverables:

- planner trigger rules
- screenshot snapshot builder
- structured planner hints
- hint expiry
- recovery flow

Success:

- planner can change goals or recover from confusion
- controller continues while planner waits
- planner latency does not move reflex-loop p95

## Phase 4: Broader Game/App Foundation

Abstract the iPhone-game-specific pieces into desktop/mobile-control primitives.

Deliverables:

- reusable capture module
- reusable action engine
- generic world-state/event interface
- iPhone game adapters
- desktop app/game adapters
- safety and focus guards

Success:

- a second demo can reuse the same loop
- only perception and policy adapters need major changes

## Open Decisions

- First iPhone demo game.
- Primary implementation language.
- macOS capture backend.
- macOS synthetic input backend.
- First iPhone Mirroring calibration method.
- Whether the first controller is heuristic, trained, or hybrid.

## Suggested Default Path

For fastest learning:

1. Use iPhone Mirroring on macOS as the primary target surface.
2. Start with a simple tap/swipe iPhone game or local iPhone Safari test page.
3. Build robust window capture, content-rect detection, and synthetic taps/swipes.
4. Move to Subway Surfers once swipe calibration is reliable.
5. Start with heuristic perception and control.
6. Add a tiny model only when heuristics hit a real wall.
7. Add the slow planner after the reflex loop already works.
