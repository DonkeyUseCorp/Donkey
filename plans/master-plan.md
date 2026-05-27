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

1. Move app-specific behavior into skills. Music, Notes, Numbers, browser
   workflows, app knowledge, and future app-specific behavior should live in
   skill packs, plugin/catalog data, generated artifacts, or memory instead of
   core Swift prompt branches.
2. Build the application-learning task. It should safely explore an app, capture
   screenshots and Accessibility trees, distill surfaces/workflows, generate
   scripts where useful, validate them, and save a reusable skill pack.
3. Wire interruption and permission gates into the UI. The notch/task UI should
   control generic harness tasks and show the exact pending approval or
   changed-course state.
4. Delete old app-specific paths once the generic path covers them. Remove
   hardcoded Music/Notes/Numbers/media/weather-style prompt rules, catalog
   special cases, repair logic, and demo-only workflow branches.

## Invariants

- Completed behavior belongs in `docs/`, not in active plans.
- Plans should stay brief and represent remaining work.
- Runtime, input, and latency claims should be tied to verifiable local traces.
- Task threads are conversations first; action execution is a routed outcome of
  the agent harness, not the default meaning of every prompt turn.
- Harness routing decisions, context compaction, local-app workflow progress,
  and shared local-model work scheduling are typed runtime state, not implicit
  prompt text.
