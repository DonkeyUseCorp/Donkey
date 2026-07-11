# Agent Guide

This repo has two kinds of written context:

- `docs/`: supported product behavior and engineering guidance.
- `plans/`: active, exploratory, or historical implementation planning.

Start with `docs/README.md` when changing supported behavior.

Use `plans/master-plan.md` as the active implementation driver when it exists and is not in `plans/done/`. It exists to coordinate the current multi-step milestone: what is already supported, what remains next, and which older plans should be treated as background or cleanup targets. Before taking the next implementation slice, read the master plan, follow its "What Should Be Done Next" section, and update it when a slice becomes supported.

Use other `plans/` files only for background unless the user explicitly asks to plan from them or the master plan names them as cleanup targets. Do not let older plans override the current master plan.

## Harness And LLM Work

Before changing the agent harness, task-intent routing, local-model adapters, LLM prompts, memory retrieval for prompt handling, or local-app decision code, read `docs/guides/agent-harness.md`.

Never infer semantic intent by string matching raw user input. Do not add phrase lists, prefixes, suffixes, regexes, app-name checks, greeting/help classifiers, or other natural-language command-text matching to decide what the user wants. Raw user text has too many variations to handle reliably. Pass the turn through an LLM or another typed model/runtime boundary first, get structured output, then do deterministic matching only on that structured output or on non-semantic technical fields.

The planner prompt is a budget: over time it shrinks, not grows. When you add a fact, tighten or replace existing wording instead of appending to it.

## Site Project

Before changing `site/` UI, routes, API handlers, or data access patterns:

- Read the relevant Next.js guide in `site/node_modules/next/dist/docs/`; this version may differ from your training data.
- Read the applicable site guidance in `docs/guides/`.
- Do not hand-write SQL migrations.
- Do not run database migrations, including `prisma migrate`, `prisma db push`, or any command that applies schema changes to Supabase or another database.
- Keep Prisma table/model definitions out of `site/prisma/schema.prisma`. Put tables in logically grouped sibling `.prisma` files under `site/prisma/`; reserve `schema.prisma` for shared Prisma configuration such as generator and datasource blocks.
- Treat `/prototype`, "the prototype route", or route-shaped prototype requests as work on the Next.js route under `site/`, not as a repository-root `prototype/` directory.

## Working Rules

- Do not touch repository-root `prototype/` unless the user explicitly asks for that filesystem path. By default, assume requested product changes are for the Mac app or the site/landing page.
- Ask before creating any new plan document.
- Manage plans deliberately: move a plan to `plans/done/` when its work is complete, and create or keep plans only for work that remains.
- Over time, prefer shrinking active `plans/` by completing work and moving finished plans to `plans/done/`.
- When writing or editing any engineering doc under `docs/`, follow `docs/guides/eng-doc-style.md`.
- Write straight up — in prompts, docs, and summaries. State what to do affirmatively and once; cut filler and negated foils (e.g. "…, which is exactly what not to do", "never re-create it").
- Update guides in `docs/guides/` only for major features or durable supported-behavior changes. Do not update guide docs for small styling tweaks, layout adjustments, copy changes, or implementation-only refactors.
- When work completes a master-plan slice, update the master plan's supported/current-boundary language and next steps in the same change.
- Keep guides explanatory. They should teach what the system is, how it works, and which boundaries matter; do not turn guides into feature inventories, implementation logs, duplicated code, or long file lists.
- Optimize guides for readability: use plain language, short sections, and only the detail a maintainer needs to understand the supported boundary. Prefer trimming outdated or repetitive detail over adding more paragraphs.
- Keep guide source entrypoints short and readable. Do not write exhaustive file inventories. Prefer a small maintainer map by subsystem or one to seven high-signal paths, and link to a source path only when it gives someone a clear place to start.
- When asked to commit, group the working changes into logical commits by concern rather than one catch-all commit, then merge into `main`. Write messages as `type(scope): summary`, where `type` is a Conventional Commits kind (`feat`, `fix`, `docs`, `refactor`, `chore`, etc.) and `scope` is the area touched (e.g. `feat(site)`, `fix(app)`, `refactor(site)`); `scope` may be omitted when an area does not apply, as in `docs:`. Do not push unless asked.
- End the commit subject with ` [rebuild]` when the change ships inside the Mac app and needs a new build: `apps/`, the Cut engine (`site/src/cut/engine/`, `site/src/cut/server/`), or bundled tooling (`tools/`, the bundled-tools scripts). Hosted-site-only changes take no label.
- Build forward by default. Prefer updating callers and contracts to the new supported shape instead of preserving old compatibility paths; ask before adding or keeping backwards-compatibility shims.
- After finishing a task, summarize what you did. Ground the summary in the actual code changes — name the files and behavior that changed, not the intent you set out with. If nothing changed, say so. When the change has a shape worth seeing — a system flow or a UI layout — include a small ASCII diagram of it.
- This is an open source project. Stay alert for security concerns, and never commit PII, API keys, tokens, credentials, private config, or other secrets.
- Keep this file stable and lightweight.
