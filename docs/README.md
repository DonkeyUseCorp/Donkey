# Donkey Docs

This folder is the product and engineering source of truth for capabilities that are already supported.

Plans describe what we might build. Guides describe what Donkey currently supports and how to maintain it.

There is an active sequencing file in `plans/master-plan.md`. When its Current
Sequence is empty, do not invent milestone work. The supported harness boundary
uses hosted model routes for model-backed decisions; local model packages and
local model weight setup are not part of the supported install path.

## Guides

Supported product and engineering guides live in `docs/guides/`. This list is the canonical index — keep it in sync when you add or rename a guide.

**The agent**

- [Agent Harness](guides/agent-harness.md) — the runtime loop that turns a request into completed work: plan, act, verify, recover, and the safety invariants.
- [Harness Deep Dive](guides/harness-deep-dive.md) — subsystem mechanics, one level below the architecture loop.
- [Decision System](guides/decision-system.md) — how a turn becomes a conversation, a question, a permission request, or guarded action, and what counts as done.
- [Donkey Vision](guides/donkey-vision.md) — the observation layer that turns on-screen windows into structured UI the agent can reason about.
- [Background Input](guides/background-input.md) — driving an app without taking over the cursor or raising it: the foreground/background decision and the delivery lanes.

**Mac app surfaces**

- [Notch](guides/notch.md) — the always-on top-center surface: task states, controls, and streaming narration.
- [User Query Overlay](guides/user-query-overlay.md) — the floating prompt composer and agent cursors, and their grounded-only, cosmetic contract.
- [Permission Pre-Gate](guides/permission-gate.md) — how macOS permissions are approved in the notch before the system dialog appears.

**Extending the agent**

- [Authoring Skills](guides/authoring-skills.md) — writing reusable skill packs that teach the agent app-specific workflows.

**Site and backend**

- [Backend API Guide](guides/backend-apis.md) — the hosted routes the Mac app and site call for model-backed work.
- [Frontend and Next.js Guidelines](guides/frontend-nextjs-guidelines.md) — route structure, server/client boundaries, styling, and data access in the site app.

**Operations**

- [Install Donkey Locally](guides/install-donkey.md) — building the app bundle and disk image for local testing.
- [Releasing Donkey](guides/releasing-donkey.md) — how production releases are built and shipped.

**Working in this repo**

- [Swift MVC Guide](guides/swift-mvc.md) — keeping product state, UI rendering, and AppKit orchestration separate in the app.
- [Code Review Guide](guides/code-review.md) — what makes a change reviewable, and how we review.
- [Engineering Doc Style Guide](guides/eng-doc-style.md) — the required structure, sentence-level rules, and post-writing test for every doc here.

Add or update an entry here when behavior becomes supported. Don't duplicate this index in subdirectories or app folders; link directly between related docs only when the relationship helps a maintainer. Write and edit docs following the [Engineering Doc Style Guide](guides/eng-doc-style.md).

## Navigation Rules

- Treat `plans/done/` as background only; do not use archived plans as active implementation instructions.
- Ask before creating a new active plan.
- Move active plans to `plans/done/` only after the behavior is implemented, documented, and verified.
- Product guides should explain supported behavior, boundaries, and verification.
- Engineering guides should explain patterns current code must follow, not speculative architecture.
- Guides should not duplicate implementation. Prefer intent, rules, and concise source entrypoints over code listings or long file inventories.
- Register a new guide once, in the Guides index above; beyond that prefer one canonical file in `docs/` and selective cross-links only where they carry context.
