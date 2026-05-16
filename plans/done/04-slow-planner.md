# Slow Planner

> Completed status: the slow planner has trigger rules, compact snapshots, validated hint publication, provider-backed local/online planner hint generation, and tests showing planner latency does not affect reflex p95.

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

## Completion Notes

- `DryRunSlowPlannerSidecar` triggers beside the dry-run reflex loop and builds compact snapshots from world state, action, trace summaries, screenshots, and memory.
- `ProviderBackedSlowPlannerHintGenerator` can try a local Ollama-compatible provider and fall back to OpenAI through the same structured planner-hint schema.
- `ValidatedPlannerHintBus` rejects invalid or unsafe hints before controller publication.
- `PlannerHintAwareControllerPolicy` exposes the latest validated hint as metadata, not direct input.
- Tests cover snapshot construction, invalid-hint rejection, hint-aware controller metadata, 30 simulated seconds without planner output, provider fallback, and reflex p95 isolation from planner latency.
