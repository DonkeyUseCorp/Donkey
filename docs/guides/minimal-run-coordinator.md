# Minimal Run Coordinator

## Supported Behavior

Donkey supports a minimal in-memory runtime coordinator for the future off-the-shelf run loop.

The coordinator can:

- accept run sessions with a user goal, target id, runtime profile, and permission policy
- keep only the latest pending live-control session request
- publish ordered `assistant`, `tool`, `lifecycle`, and `reflex` events
- move through explicit lifecycle states for start, pause, resume, completion, abort, timeout, and failure
- deny unsafe input tool calls by default
- mark aborts and timeouts as requiring held-input release
- build bounded planner context from the current session, world-state summary, transcript summary, valid hints, and recent failures

This is a coordination foundation only. It does not capture the screen, run perception models, call LLMs, or execute OS input.

## Technical Guidelines

- Keep shared event, policy, lifecycle, and context types in `DonkeyContracts`.
- Keep coordinator state and append ordering in `DonkeyRuntime`; UI code should read status through narrow provider boundaries.
- Treat `RunCoordinator` as the owner of lifecycle and event ordering, not as the owner of perception, controller internals, or input backends.
- Keep input actions denied unless a caller provides a policy that explicitly allows them.
- Preserve latest-request-wins behavior for live-control sessions so stale work cannot build up behind the reflex loop.
- Use sampled or summarized reflex events until a measured trace sink exists.

## Verification

From `apps/Donkey/`:

```sh
swift test
```

The runtime tests should cover lifecycle ordering, abort and timeout safety, latest-session queue drops, tool permission denial, event-store ordering, and context compaction.

## Source Entry Points

- Runtime contracts live in `apps/Donkey/Sources/DonkeyContracts/RunLoopContracts.swift`.
- Runtime coordination lives in `apps/Donkey/Sources/DonkeyRuntime/`.
- The source plan remains active in `plans/20-off-the-shelf-run-loop.md`.
