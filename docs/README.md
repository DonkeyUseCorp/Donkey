# Donkey Docs

This folder is the product and engineering source of truth for capabilities that are already supported.

Plans describe what we might build. Guides describe what Donkey currently supports and how to maintain it.

There is an active milestone plan in `plans/master-plan.md`. It tracks the unfinished work needed before the fast local navigation and AI-harness roadmap can be considered complete: generic local-app task knowledge, local JSON/JSONL task-definition loading, installed-app/task resolution, local-model command parsing with catalog validation, local task-context intake, Accessibility control discovery and action planning, review-first document form-fill planning, Parakeet-only local voice transcription, YOLO screenshot segmentation and local UI-understanding sidecar boundaries, post-install local runtime setup without bundled model weights, setup-managed command-parser LLM weight download, semantic memory/redaction/model-observability scaffolding, local navigation, guarded input, result verification, latency reporting, and optional slow planner recovery. Weather lookup, media playback, and document form-fill are benchmark definitions for this generic system, not source-specific architectures.

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
