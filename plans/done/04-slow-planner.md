# Slow Planner

> Archived status: historical context only. This file is not an active implementation queue. Supported behavior lives in `docs/`; future work from this idea needs a fresh active plan created deliberately.

## Goal

Handle strategy and recovery without slowing down the reflex loop.

The slow planner is useful, but never frame-critical.

## Responsibilities

- setting goals
- choosing high-level strategy
- interpreting quests or menus
- selecting resources or inventory
- recovering from confusion
- explaining what the agent is doing
- producing new controller hints

## Inputs

- recent world-state history
- occasional high-resolution screenshots
- OCR snippets
- controller failure events
- game-specific memory
- user instructions

## Outputs

- active goal
- preferred policy
- target priority
- route or waypoint hints
- menu instructions
- recovery action
- updated memory

## Cadence

Run the planner only when useful:

- every few seconds
- when the scene changes
- when confidence drops
- when the controller reports repeated failure
- when a goal is completed
- when the user gives a new instruction

## Architecture

```text
Trace Buffer
  -> Planner Trigger
  -> Snapshot Builder
  -> VLM/LLM Planner
  -> Controller Hints
```

The planner writes hints into shared state. The controller reads the latest available hints.

## Planner Prompt Shape

Planner prompts should be compact:

- current goal
- latest summarized state
- recent failures
- screenshot when needed
- allowed hint schema

The planner should return structured output, not prose, for the controller.

## Failure Handling

If the planner is slow, unavailable, or wrong:

- controller continues with last valid hints
- stale hints expire
- repeated failures trigger fallback policy
- user can interrupt or reset goal

## First Milestones

1. Define planner hint schema.
2. Build trigger rules.
3. Add snapshot capture outside the frame loop.
4. Implement a basic planner that returns JSON hints.
5. Add hint expiry and validation.

## Acceptance Criteria

- Planner latency does not affect p95 reflex latency.
- Controller can run for at least 30 seconds without planner output.
- Planner output is validated before it reaches the controller.

