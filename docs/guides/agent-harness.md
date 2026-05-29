# Agent Harness

```text
User turn
  |
  v
Model boundary -> structured intent, risk, plan, verification
  |
  v
Generic harness task state
  |
  v
Tool registry -> guarded executor -> structured observation
  |                                      |
  +----------- verify / recover / gate --+
```

The agent harness is Donkey's app-agnostic runtime boundary for turning a user
turn into durable task progress. It owns intent routing, bounded context,
planning, guarded tool execution, verification, recovery, permission gates,
clarification, pause/resume, interruption, and multi-task state.

Keep the harness generic. App-specific behavior belongs in task definitions,
catalog data, skills, generated artifacts, plugins, or memory. Core harness
code must not add phrase lists, app-name branches, or one-off natural-language
conditionals.

## Runtime Shape

A user-query turn enters the generic lifecycle before any local-app executor is
selected. The model boundary returns structured intent, risk/ambiguity, context
needs, plan steps, verification criteria, fallback policy, and clarification
policy. Deterministic Swift then validates the structured plan against the tool
registry, permissions, supported app catalog, and task state.

The loop is:

```text
intake
-> intent analysis
-> context gathering
-> world model update
-> planning
-> execute one guarded tool step
-> verify
-> recover, continue, clarify, ask permission, or complete
```

Desktop work is not a single model completion. The harness observes, acts,
records evidence, verifies, and may replan. Models choose structured tool calls;
Swift owns task state, tool validation, focus checks, permission gates,
execution, and result recording.

## Task State

Each task has its own durable state: goal, structured intent, context, world
model, plan, granted permissions, tool history, pending continuation, and
lifecycle status.

Active/waiting tasks stay task-local. A pause, clarification, permission gate,
interruption, cancellation, or failed-safe state must affect only the selected
task.

Threads store conversation events and active task ids. Task snapshots store
execution state. Compaction snapshots record what bounded context was sent to a
model so decisions remain inspectable.

## Context And Intent

The harness never sends raw unbounded history to a model. Compaction keeps the
current turn, relevant active/waiting task state, recent useful evidence,
summaries, memory snippets, pending questions/permissions, and bounded assets.

Never infer semantic intent by matching raw user text. Pass the turn through an
LLM or another typed model/runtime boundary first. After that, deterministic
code may match typed fields such as tool names, app ids, schema values,
permissions, filesystem paths, and Accessibility roles/actions.

The app catalog is part of the model boundary. If a requested app or capability
is not supported or is still refreshing, surface conversation, clarification,
waiting, or failed-safe state rather than silently executing an unsupported
candidate.

## Tools

Tools are registered through the generic registry. A descriptor declares the
tool name, plugin id, schemas, required permissions, safety class, required
context, verification hints, and metadata. The planner sees descriptors and
schemas, not Swift implementation details.

Tool results return structured observations that update the task world model.
Waiting states are hard stops:

- missing permission moves the task to `waitingForPermission`
- missing required user detail moves the task to `waitingForUser`
- dangerous ambiguity asks before acting
- verification failure chooses recovery, review, or failed-safe state

Core tool families cover conversation, clarification, permission requests,
memory, skills, app lookup, observation, UI element actions, text/keyboard
input, AppleScript/script generation and execution, verification, learning, and
lifecycle control.

## Computer Use

Computer use is a tool family inside the harness. Accessibility is the primary
source for actionable elements. Screenshots, vision, OCR, and hover evidence
enrich the world model and can provide fallback targets when Accessibility is
insufficient.

Input must be guarded by target focus, permission policy, element eligibility,
allowed action type, safety class, and verification criteria. Coordinate input
is a fallback path, not a shortcut around those checks.

Verification must be evidence-backed. A command is not complete merely because
the target app is focused. The harness needs post-action evidence such as a
guarded command trace, visible text, selected state, app-reported result, or
screenshot-backed observation.

## AppleScript And Scripts

AppleScript is a tool path, not a hardcoded helper path. Generation creates a
script artifact; it does not execute the script. Execution may run only a
validated, generated, or user-reviewed artifact through the guarded backend,
with target app, permissions, action metadata, and verification evidence.

Dynamic AppleScript follows the same artifact boundary and should stay small:

```text
automation.applescript.generate
-> automation.applescript.validate
-> automation.applescript.execute
-> observe
-> verify
```

The generation step receives structured target-app, goal, entity,
allowed-action, and verification inputs for one bounded target-app operation or
a very small sequence. It must not try to build a full automation pipeline;
observation, clicking, recovery, and verification stay as separate harness
steps. If the requested operation is not doable as a small scoped AppleScript,
generation should fail cleanly and the plan should use observation,
Accessibility, screenshot, or UI tools instead.

Planner output must not contain raw script source for dynamic AppleScript. A
child generation boundary creates the artifact source, and the plan reuses the
same `scriptArtifactID` across generation, validation, and execution.

App-specific AppleScript belongs in skill-local scripts, generated artifacts,
plugins, catalog entries, or user-reviewed definitions. Do not add app-named
Swift helpers such as `musicPlaybackScript`.

## Skills And Learning

Skills are reusable harness extensions. Skill lookup gives the planner bounded
instructions, descriptors, and validated scripts without putting app-specific
branches into core runtime code.

Learning an application is a skill-producing harness task. It gathers bounded
screenshot and Accessibility evidence, explores only safe/reversible states
unless the user approves more, distills an app profile and workflow recipes,
and saves a reusable skill pack with any validated scripts.

## Source Map

Start here:

- `apps/Donkey/Sources/DonkeyHarness/` for task state, registry, tools, skills,
  thread storage, and generic runtime execution.
- `apps/Donkey/Sources/DonkeyContracts/` for shared contracts across modules.
- `apps/Donkey/Sources/DonkeyRuntime/` for guarded local-app execution,
  Accessibility, screenshots, app/window observation, and input backends.
- `apps/Donkey/Sources/DonkeyAI/` for hosted model routing and adapters.
- `apps/Donkey/Sources/Donkey/` for user-query integration.

Tests live in `apps/Donkey/Tests/DonkeyRuntimeTests/`. Use focused `swift test`
runs from `apps/Donkey/` when changing harness behavior.
