# Agent Guide

This repo has two kinds of written context:

- `docs/`: supported product behavior and engineering guidance.
- `plans/`: exploratory or historical implementation planning.

Start with `docs/README.md` when changing supported behavior. Use `plans/` only for background unless the user explicitly asks to plan.

## Working Rules

- Ask before creating any new plan document.
- Manage plans deliberately: move a plan to `plans/done/` when its work is complete, and create or keep plans only for work that remains.
- Over time, prefer shrinking active `plans/` by completing work and moving finished plans to `plans/done/`.
- When a completed capability changes, update the relevant guide in `docs/guides/`.
- Keep guides explanatory. Describe supported behavior, boundaries, and engineering intent; do not duplicate code or maintain long file inventories.
- Link to source paths only when a maintainer needs an entrypoint.
- Keep this file stable and lightweight.
