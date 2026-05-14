# Donkey Docs

This folder is the product and engineering source of truth for capabilities that are already supported.

Plans describe what we might build. Guides describe what Donkey currently supports and how to maintain it.

## Product Guides

- [Pointer Prompt Overlay](guides/pointer-prompt-overlay.md): command-click agent pointer and ChatGPT-style `Make this so` composer that follows the mouse at a fixed offset.

## Engineering Guides

- [Swift MVC Guide](guides/swift-mvc.md): Swift/AppKit/SwiftUI organization rules for model-view-controller boundaries.

## Navigation Rules

- Add a guide here when a plan moves to `plans/done/`.
- Product guides should explain supported behavior, boundaries, and verification.
- Engineering guides should explain patterns current code must follow, not speculative architecture.
- Guides should not duplicate implementation. Prefer intent, rules, and concise source entrypoints over code listings or long file inventories.
