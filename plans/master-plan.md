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

1. **Deterministic pipeline runner** — `plans/harness-deterministic-pipeline-runner.md`.
   Collapse fixed multi-tool recipes from one planner round-trip per tool into a
   single routed action that runs the recipe in code and calls the model only for
   genuine judgment. The runner (`MediaPipeline`) and its first consumer
   (`shorts.make` → `ShortsOrchestrator`, one model call for a whole shorts run) are
   **supported**. Remaining: migrate `pdf.fill` onto the runner (code unification,
   not a cost fix), and capture a real before/after trace.

2. **Local browser automation via the browser-use CLI (CDP)** —
   `plans/local-browser-cdp-automation.md`. Add a free "act in your own browser"
   rung beside Browser Use Cloud: bundle the `browser-use` Python sidecar (no
   Chromium), drive the user's installed Chrome over CDP in agentic `run` mode, and
   route the agent's LLM through a metered Donkey backend relay. Supports a
   dedicated persistent profile and a consented seeded-from-real profile. Starts
   at Phase 1 (sidecar + CDP smoke path).

3. **Cut project sharing (read-only links)** — `plans/cut-project-sharing.md`.
   Google-doc-style share links for cloud Cut projects: a stable revocable
   token, an unauthenticated read-only `/api/cut-share/:token/*` surface with a
   sanitized doc, and a viewer page that live-follows the owner's autosaves by
   polling the doc version. Cloud projects only; not started.

## Invariants

- Completed behavior belongs in `docs/`, not in active plans.
- Plans should stay brief and represent remaining work.
- Runtime, input, and latency claims should be tied to verifiable local traces.
- Task threads are conversations first; action execution is a routed outcome of
  the agent harness, not the default meaning of every prompt turn.
- Harness routing decisions, context compaction, local-app workflow progress,
  and shared local-model work scheduling are typed runtime state, not implicit
  prompt text.
