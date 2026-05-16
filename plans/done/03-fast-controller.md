# Fast Controller

> Archived status: historical context only. This file is not an active implementation queue. Supported behavior lives in `docs/`; future work from this idea needs a fresh active plan created deliberately.

## Goal

Make real-time decisions from world state without waiting on slow reasoning.

The fast controller is the agent's reflex system.

## Responsibilities

- movement
- aiming
- clicking
- dodging
- combat reactions
- menu navigation
- repeated game loops
- emergency recovery actions

## Non-Responsibilities

- long-term strategy
- quest interpretation
- inventory planning
- natural-language reasoning
- visual explanation
- broad desktop task planning

Those belong to the slow planner.

## Controller Design

Start simple and deterministic:

```text
World State
  -> Policy Selector
  -> Action Policy
  -> Action Command
```

The off-the-shelf perception path uses the same contract:

```text
Detector / Segmenter / OCR / Template
  -> Game State
  -> Rule / State Machine
  -> Action Command
```

See [20-off-the-shelf-run-loop.md](20-off-the-shelf-run-loop.md) for the off-the-shelf runtime plan.

The policy selector chooses a small controller:

- `combat_policy`
- `navigation_policy`
- `menu_policy`
- `avoidance_policy`
- `recovery_policy`

Each policy should have a bounded runtime and clear inputs.

## Policy Options

Use the simplest viable method first:

| Situation | Method |
| --- | --- |
| target clicking | nearest/most valuable target heuristic |
| dodging | vector away from hazard |
| movement | waypoint or potential-field controller |
| repeated loops | finite-state machine |
| game-specific skill | target-specific rule set over detector/OCR/SAM outputs |
| uncertainty | safe default plus slow-planner request |

For aiming, movement, dodging, recoil control, and tap/swipe timing, do not use an LLM. Use deterministic logic over current perception state.

## Timing

The controller should run faster than perception. Target decision time:

- baseline: 1-20ms
- stretch: under 5ms

## Planner Interaction

The slow planner can update:

- current goal
- policy weights
- target priority
- route hints
- recovery instructions

The fast controller should treat planner output as configuration, not a blocking dependency.

## Safety Rails

- Rate-limit repeated inputs.
- Add maximum hold durations for keys.
- Add emergency input release.
- Stop acting if the game window loses focus.
- Stop acting if world-state confidence is too low for too long.

## First Milestones

1. Define the world-state schema the controller consumes.
2. Implement deterministic policies for the first supported game.
3. Add policy-selection logic.
4. Add confidence-aware fallback behavior.
5. Record every chosen action with the state snapshot id.
6. Add detector/OCR/template-derived state inputs.
7. Replay recorded state traces before live input.

## Acceptance Criteria

- p95 decision time is under 20ms.
- Controller can keep acting while planner is unavailable.
- Actions are reproducible from recorded world-state traces.
- Perception output cannot bypass action projection or safety guards.
