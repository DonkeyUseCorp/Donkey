# Agent Harness

```text
User turn
  |
  v
Generic harness task state (goal, world model, history) <--+
  |                                                         |
  v                                                         |
Model boundary -> the single next tool call                |
  |   (see, act, verify, respond, clarify, or complete)    |
  v                                                         |
Tool registry -> guarded executor -> structured observation
  |                                                         |
  +-- update world model, then re-plan ---------------------+
      (or hard-stop at a permission / clarification gate)
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
selected. The harness compacts context into task state, then runs a loop: each
step it asks the model boundary for the single next tool call given the current
world model, validates and executes that one call deterministically, records the
resulting observation, and asks again. Planning happens per observation, not as
one upfront plan.

The loop is:

```text
intake
-> compact context into task state
-> ask the model boundary for the next tool call
-> validate against registry, permissions, and task state
-> execute one guarded tool step
-> record the structured observation into the world model
-> re-plan, or hard-stop at a clarification / permission gate
```

Desktop work is not a single model completion. The harness observes, acts, and
records evidence one step at a time, re-planning after each observation. The
model chooses the next tool — including when to see, verify, respond, clarify,
or complete — while Swift owns task state, tool validation, focus checks,
permission gates, execution, and result recording.

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

## Model Boundary And Adapters

The model boundary is pluggable. The harness asks an abstract boundary for the
single next tool call; a model adapter translates that request into one
provider's wire format and parses the provider's response back into a validated
registry tool call. Adapters live in `DonkeyAI/`, behind the generic registry —
task state and the planner never see provider details.

An adapter's job is narrow and total:

```text
next-tool-call request
-> render registry descriptors + schemas into the provider's tool format
-> send compacted task state as the prompt (never raw history)
-> provider
-> parse response into one validated registry tool call, or a boundary error
```

Provider-side failures (refusal, truncation, malformed call) map into harness
states the planner already handles, not ad hoc retries inside the adapter.

Because adapters are interchangeable, the boundary supports a primary hosted
model plus a fallback. A fallback adapter targeting an open-weights model that
emits tool calls as structured text — for example the Hermes function-call
convention — is a supported shape: it implements the same render/parse contract,
reuses the same registry and schemas, and changes nothing in the runtime loop.
Keep format-specific parsing inside the adapter; the rest of the harness only
ever sees a validated tool call.

What stays out of adapters: task state, permission gates, verification,
planning, and computer-use guarding. An adapter formats requests and parses tool
calls; it never decides intent, executes tools, or holds task state.

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
- on verification failure the planner re-plans to recover, clarify, or fail safe

Core tool families cover conversation, clarification, permission requests,
memory, skills, app lookup, observation, UI element actions, text/keyboard
input, AppleScript/script generation and execution, verification, learning, and
lifecycle control.

## Computer Use

Computer use is a tool family inside the harness, and seeing and acting are each
plain tools the planner chooses per step — not a fixed pipeline. The harness
re-plans after every observation, so the model looks, sees the result, then picks
the next tool.

To **see**, it can read the Accessibility tree (fast, structured, best for native
apps) or capture and analyze a screenshot with vision (works for any pixels, e.g.
canvas or Electron content). Either returns elements into the world model.
Accessibility is preferred when it's sufficient; vision is the fallback when it
isn't.

To **act**, it can click an element the AX tree or vision returned, type or press
keys, or generate and run an AppleScript — whichever fits. Clicking an
Accessibility control prefers a native Accessibility press (`AXPress`) and falls
back to a guarded coordinate click on the control's frame; vision elements click
by coordinate. Either way this is not a shortcut around the focus and permission
checks below. The planner can also answer conversationally or ask the user to
clarify instead of acting — responding and clarifying are themselves tools.

A non-LLM monitor watches the frontmost window's screenshot fingerprint and
re-parses on large changes, keeping the vision parse cache warm so a capture is
usually reused instantly rather than paid for inline.

Input must be guarded by target focus, permission policy, element eligibility,
allowed action type, safety class, and verification criteria. Coordinate input
is a fallback path, not a shortcut around those checks.

Verification must be evidence-backed. A command is not complete merely because
the target app is focused. The harness needs post-action evidence such as a
guarded command trace, visible text, selected state, app-reported result, or
screenshot-backed observation.

Pointer playback is separate from input. It may rotate, travel, hold, and label
the path the agent planned or observed, while AX, AppleScript, keyboard input,
or guarded coordinate fallback perform the real work.

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
- `apps/Donkey/Sources/DonkeyAI/` for hosted and fallback model routing and
  adapters.
- `apps/Donkey/Sources/Donkey/` for user-query integration.

Tests live in `apps/Donkey/Tests/DonkeyRuntimeTests/`. Use focused `swift test`
runs from `apps/Donkey/` when changing harness behavior.
