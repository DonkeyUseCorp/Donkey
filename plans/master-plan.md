# Master Plan

This file is the permanent sequencing guide for active work. Keep it present
even when there are no active tasks.

## How To Process Tasks

- Start with `docs/README.md`, then read the guide that describes the supported
  behavior being changed.
- Treat `docs/` as supported behavior and `plans/` as task coordination context.
- Put implementation details in focused plan files. Use this file to sequence
  those plans, not to keep long implementation logs.
- Work the items in `Current Sequence` from top to bottom unless the user gives
  a newer priority.
- Before starting an item, check whether the work is already complete in code
  and docs.
- When an item is complete, update the relevant guide, move completed plan files
  to `plans/done/`, and remove the item from this sequence.
- If there are no active tasks, leave `Current Sequence` empty and do not invent
  new work.

## Current Sequence

- Better Donkey Vision testing UI. Vision (RunPod OmniParser V2) now renders on
  the developer debug overlay (`DONKEY_DEBUG_OVERLAY`, fused with AX, gated behind
  `remoteAIEngine` in `DebugUIInspectionCoordinator`). That overlay is a debugging
  surface, not a real product/testing UI. We need a better way to view and
  evaluate raw vision output (boxes, labels, per-window parse latency, hit/skip on
  the local image-hash cache) while iterating. Scope/shape TBD.
  - Iteration affordance now in place: an env-gated "vision navigation" route
    (`DONKEY_VISION_NAV=1`, `VisionNavigationMode` in `UserQueryCommandHandler`)
    sends a typed query straight to `VisionActionDriver` against the frontmost
    app, so you can type one request after another and watch it navigate. It
    console-logs end-to-end grounding latency (time-to-first-action and total)
    under the `vision-grounding` logger / `[grounding-e2e]` stdout prefix. The
    flag is configurable/revertible; this is a dev-test path, not yet a product
    surface.

## Invariants

- Completed behavior belongs in `docs/`, not in active plans.
- Plans should stay brief and represent remaining work.
- Runtime, input, and latency claims should be tied to verifiable local traces.
- Task threads are conversations first; action execution is a routed outcome of
  the agent harness, not the default meaning of every prompt turn.
- Harness routing decisions, context compaction, local-app workflow progress,
  and shared local-model work scheduling are typed runtime state, not implicit
  prompt text.
