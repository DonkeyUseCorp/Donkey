# Rollout Plan

## Phase 0: First Supported Target

Pick the first iPhone Mirroring target and define the initial supported agent behavior.

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

## Phase 2: Competent iPhone Game Target

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

## Phase 2.5: Off-The-Shelf Vision Upgrade

Add stronger off-the-shelf perception only after the deterministic loop exposes a real gap.

Deliverables:

- fixed game-state schema
- YOLO-family detector candidate
- SAM/MobileSAM/FastSAM fallback candidate, if masks are needed
- OCR or template matcher for UI/text signals
- runtime benchmark through the target execution provider
- replay state/action report
- live input-disabled canary

Success:

- off-the-shelf perception improves one target metric against the simpler baseline
- detector/segmenter/OCR p95 stays inside the reflex budget
- all perception outputs pass through state validation and safety guards

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

- a second target can reuse the same loop
- only perception and policy adapters need major changes

## Open Decisions

- First supported iPhone game.
- Primary implementation language.
- macOS capture backend.
- macOS synthetic input backend.
- First iPhone Mirroring calibration method.
- Whether the first controller is pure rules or rules plus off-the-shelf perception.

## Suggested Default Path

For fastest learning:

1. Use iPhone Mirroring on macOS as the primary target surface.
2. Start with a simple tap/swipe iPhone game or local iPhone Safari test page.
3. Build robust window capture, content-rect detection, and synthetic taps/swipes.
4. Move to Subway Surfers once swipe calibration is reliable.
5. Start with heuristic perception and control.
6. Add a tiny model only when heuristics hit a real wall.
7. Add SAM/OCR/LLM slow-path recovery only where simple perception fails.
8. Add the slow planner after the reflex loop already works.
