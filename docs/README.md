# Donkey Docs

This folder is the product and engineering source of truth for capabilities that are already supported.

Plans describe what we might build. Guides describe what Donkey currently supports and how to maintain it.

There is currently no active plan in `plans/`. The roadmap-era plans have been moved to `plans/done/` as historical context because they either describe already-supported slices or future work that is not actionable in this repo without a fresh product/target decision.

## Product Guides

- [Pointer Prompt Overlay](guides/pointer-prompt-overlay.md): double-Command standard macOS-style `Make this so` composer that opens near the mouse at a fixed offset.

## Engineering Guides

- [Swift MVC Guide](guides/swift-mvc.md): Swift/AppKit/SwiftUI organization rules for model-view-controller boundaries.
- [Minimal Run Coordinator](guides/minimal-run-coordinator.md): in-memory run lifecycle, events, policy checks, session queueing, context compaction, manual capture orchestration, and reflex trace boundary.

## Navigation Rules

- Add a guide here when a plan moves to `plans/done/`.
- Treat `plans/done/` as background only; do not use archived plans as active implementation instructions.
- Ask before creating a new active plan.
- Product guides should explain supported behavior, boundaries, and verification.
- Engineering guides should explain patterns current code must follow, not speculative architecture.
- Guides should not duplicate implementation. Prefer intent, rules, and concise source entrypoints over code listings or long file inventories.
