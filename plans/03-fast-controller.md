# Fast Controller

> Active status: not complete. Current controller support is deterministic and traceable for metadata/local-navigation dry-runs, but not yet proven against a live fast-navigation benchmark such as Weather lookup.

## Goal

Make local task decisions from typed state without waiting on slow reasoning.

The fast controller is the agent's reflex system. For the first product proof, that means deterministic navigation and UI actions; game movement is a later specialization of the same navigation loop.

## Responsibilities

- app launch/focus decisions
- search/type/select decisions
- clicking or Accessibility action selection
- menu navigation
- repeated app workflows
- result verification
- safe fallback and recovery triggers
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

The first app-task path uses the same contract:

```text
TaskIntent + App Observation
  -> Task State
  -> Weather Lookup Policy
  -> Semantic Action Command
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
- `weather_lookup_policy`
- `app_search_policy`

Each policy should have a bounded runtime and clear inputs.

## Policy Options

Use the simplest viable method first:

| Situation | Method |
| --- | --- |
| target clicking | nearest/most valuable target heuristic |
| Weather lookup | finite-state app task policy over app focus/search/result state |
| app search box | type normalized entity once, submit/select, then verify |
| dodging | vector away from hazard |
| movement | waypoint or potential-field controller |
| repeated loops | finite-state machine |
| game-specific skill | target-specific rule set over detector/OCR/SAM outputs |
| uncertainty | safe default plus slow-planner request |

For aiming, movement, dodging, recoil control, and tap/swipe timing, do not use an LLM. Use deterministic logic over current perception state.

For app workflows, do not use an LLM to choose each click or keystroke. Use a task adapter and deterministic policy over current app state. The LLM may only produce a validated intent or recovery hint.

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
- ambiguous entity resolution when deterministic parsing fails

The fast controller should treat planner output as configuration, not a blocking dependency.

## Safety Rails

- Rate-limit repeated inputs.
- Add maximum hold durations for keys.
- Add emergency input release.
- Stop acting if the target app or later game window loses focus.
- Stop acting if world-state confidence is too low for too long.
- Stop before interacting with sensitive apps, login screens, payment screens, or private-message surfaces.

## First Milestones

1. Define the `TaskIntent` and task-state schema the controller consumes for Weather lookup.
2. Implement `weather_lookup_policy` for launch/focus/search/select/verify.
3. Add policy-selection logic for local app tasks.
4. Add confidence-aware fallback behavior and recovery hint triggers.
5. Record every chosen action with the intent id and state snapshot id.
6. Add Accessibility/window/screenshot-derived state inputs.
7. Replay recorded app-state traces before live input.
8. Keep detector/OCR/template-derived game inputs as follow-on policies.

## Acceptance Criteria

- p95 decision time is under 20ms.
- Controller can keep acting while planner is unavailable.
- Actions are reproducible from recorded world-state traces.
- Perception output cannot bypass action projection or safety guards.
- Weather lookup can complete from parsed intent using deterministic state transitions.
