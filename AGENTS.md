# Agent Guide

This repo has two kinds of written context:

- `docs/`: supported product behavior and engineering guidance.
- `plans/`: active, exploratory, or historical implementation planning.

Start with `docs/README.md` when changing supported behavior.

Use `plans/master-plan.md` as the active implementation driver when it exists and is not in `plans/done/`. It exists to coordinate the current multi-step milestone: what is already supported, what remains next, and which older plans should be treated as background or cleanup targets. Before taking the next implementation slice, read the master plan, follow its "What Should Be Done Next" section, and update it when a slice becomes supported.

Use other `plans/` files only for background unless the user explicitly asks to plan from them or the master plan names them as cleanup targets. Do not let older plans override the current master plan.

## Site Project

Before changing `site/` UI, routes, API handlers, or data access patterns:

- Read the relevant Next.js guide in `site/node_modules/next/dist/docs/`; this version may differ from your training data.
- Read the applicable site guidance in `docs/guides/`.
- Do not run database migrations, including `prisma migrate`, `prisma db push`, or any command that applies schema changes to Supabase or another database.

## Working Rules

- Do not touch `prototype/` unless the user explicitly asks for prototype work. By default, assume requested product changes are for the Mac app or the site/landing page.
- Ask before creating any new plan document.
- Manage plans deliberately: move a plan to `plans/done/` when its work is complete, and create or keep plans only for work that remains.
- Over time, prefer shrinking active `plans/` by completing work and moving finished plans to `plans/done/`.
- Update guides in `docs/guides/` only for major features or durable supported-behavior changes. Do not update guide docs for small styling tweaks, layout adjustments, copy changes, or implementation-only refactors.
- When work completes a master-plan slice, update the master plan's supported/current-boundary language and next steps in the same change.
- Keep guides explanatory. Describe supported behavior, boundaries, and engineering intent; do not duplicate code or maintain long file inventories.
- Link to source paths only when a maintainer needs an entrypoint.
- Keep this file stable and lightweight.
