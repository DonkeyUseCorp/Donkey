# Donkey Docs

This folder is the product and engineering source of truth for capabilities that are already supported.

Plans describe what we might build. Guides describe what Donkey currently supports and how to maintain it.

There is an active sequencing file in `plans/master-plan.md`. When its Current
Sequence is empty, do not invent milestone work. The supported harness boundary
uses hosted model routes for model-backed decisions; local model packages and
local model weight setup are not part of the supported install path.

## Guides

Supported product and engineering guides live in `docs/guides/`.

Add or update a guide there when behavior becomes supported. Do not maintain duplicate guide indexes in subdirectories or app folders; use descriptive filenames and link directly from related docs only when the relationship helps a maintainer.

## Navigation Rules

- Treat `plans/done/` as background only; do not use archived plans as active implementation instructions.
- Ask before creating a new active plan.
- Move active plans to `plans/done/` only after the behavior is implemented, documented, and verified.
- Product guides should explain supported behavior, boundaries, and verification.
- Engineering guides should explain patterns current code must follow, not speculative architecture.
- Guides should not duplicate implementation. Prefer intent, rules, and concise source entrypoints over code listings or long file inventories.
- New docs do not need to be registered in multiple places. Prefer one canonical file in `docs/` and selective cross-links only where they carry context.
