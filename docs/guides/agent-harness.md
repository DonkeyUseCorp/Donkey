# Agent Harness

## What It Is

The agent harness is Donkey's app-agnostic runtime boundary for turning a user
turn into durable task progress. It owns the lifecycle around intent,
context-gathering, world modeling, planning, tool execution, verification,
recovery, permission gates, clarification, pause/resume, interruption, and
multi-task coordination.

The generic harness contracts live in `apps/Donkey/Sources/DonkeyHarness/`.
New agent capabilities should plug into that module through tools, skills,
scripts, plugins, catalogs, or memory. Do not add app-specific branches,
phrase lists, or one-off workflow conditionals to the core harness.

Bundled local-app skills now carry the app-specific planning guidance for
Music/media, browser navigation, notes/text writing, spreadsheet tables, and
weather lookup. Task-intent model calls receive those skills as bounded skill
context alongside task definitions, app catalog data, and memory.

The existing pointer-prompt and local-app runner code still exists while the
product migrates onto the generic harness. New work should build toward the
generic registry and avoid expanding the older app-specific paths.

Pointer-prompt local-app execution now enters the generic lifecycle before it
uses the older live-runner backend. The hosted planning boundary emits the
`generic_harness_planning` packet: structured intent, ambiguity/risk,
context needs, plan steps, verification criteria, fallbacks, and clarification
policy. The bridge stores that packet in generic task intent/plan state, then
uses registry-backed executors for generic validation, state updates, gates,
and lifecycle behavior. The older runner remains as the pointer-prompt bridge
for legacy concrete desktop workflows.

## Core Model

Every task has its own durable state:

- task id and thread id
- current goal
- structured intent analysis
- gathered context
- world model
- plan
- granted permissions
- tool history
- pending continuation
- lifecycle status

Supported task statuses are:

- `running`
- `paused`
- `waitingForUser`
- `waitingForPermission`
- `interrupted`
- `resuming`
- `completed`
- `failedSafe`
- `cancelled`

Multiple tasks may be active at once. Mutable execution state must stay
task-local unless it is stored in an explicit task-safe service. A pause,
clarification gate, permission gate, or cancellation affects only the selected
task; it must not block unrelated active tasks.

## Thread Storage

Threads are the durable conversation record. The generic harness defines a
thread-store boundary for threads, events, assets, task snapshots, task events,
and compaction snapshots. In tests this can be backed by an in-memory store; in
the app the default generic lifecycle uses a file-backed local store under the
user's Application Support directory. Harness code should depend on this
generic store contract rather than reaching into UI-specific persistence.

A thread record stores the user-visible conversation and the active task ids.
Task state stores execution details such as world model, plan, permissions,
tool history, and pending continuations. Summaries are stored as thread events
with the `summary` role. Compaction snapshots store the selected event, asset,
and task ids plus truncation/drop metadata so model context remains
inspectable. Keeping thread records, task snapshots, and compaction metadata
separate lets one thread coordinate multiple active tasks without mixing their
execution state.

## Smart Compaction

The harness never sends raw unbounded history to a model. Before model-backed
intent routing, generic planning, or slow-planner hint generation, compaction
builds a bounded context packet. It keeps the current turn, active and waiting
task state, pending questions or permissions, pinned events, durable summaries,
the most recent useful events, recent tool summaries, memory summaries, and a
bounded asset list.

Large event bodies are truncated. Raw screenshots, full Accessibility trees,
script source, and long tool outputs should be saved as artifacts or structured
records and summarized into the prompt. Compaction metadata records what was
included, dropped, or truncated so the decision remains inspectable.

Pointer-prompt hosted intent calls consume the generic compacted thread context
rather than ad hoc thread snippets. Slow planner calls consume a compacted run
context, including bounded world-state, failure, hint, memory, and semantic
memory summaries.

## Turn Flow

The desired loop is:

```text
intake
-> intent analysis
-> context gathering
-> world model update
-> planning
-> execute one validated tool step
-> verify
-> recover, continue, clarify, or complete
```

The harness should not treat desktop work as a single model completion. It
should observe, act, verify, and replan. The planner may propose the next tool
step, but deterministic Swift owns task state, tool validation, permissions,
focus checks, execution, and result recording.

If the user interrupts a task, the harness classifies whether the turn starts a
new task, modifies the current task, cancels, pauses, resumes, answers a
clarification, grants permission, or is conversation. A course change updates
the existing task goal/world model/plan and resumes from the checkpoint instead
of blindly restarting.

## Stop Points

Waiting states are hard stop points.

If a tool lacks permission, the task moves to `waitingForPermission`, stores a
pending continuation, asks for the specific permission, and does not execute
more tools until approval is recorded.

If required information is missing, the task moves to `waitingForUser`, stores
the pending continuation, asks a specific question, and resumes only after the
answer is attached.

Dangerous ambiguity must ask before acting. Safe ambiguity may be inferred.
Recoverable ambiguity should use available tools first, such as memory, app
search, screen observation, or skill lookup, and ask only if uncertainty remains
material.

## Tools And Plugins

Tools are registered through the generic tool registry. A tool descriptor
declares:

- name
- plugin id
- summary
- input/output schema
- required permissions
- safety class
- required context
- verification hints
- metadata

The planner sees tool descriptors and schemas, not Swift implementation
details. Built-in registry executors validate inputs and permissions for memory
lookup, skills, app lookup, observation, element actions, text/keyboard input,
script generation/validation/execution, verification, and lifecycle changes.
Tool results return structured observations that update the task's world model.

Core built-in tools cover conversation, user clarification, permission
requests, memory lookup, skill lookup, skill-script lifecycle, app discovery,
screen observation, UI element discovery and action, text and keyboard input,
AppleScript generation/execution, state verification, and task lifecycle
control.

Additional plugins should register tools through the same interface. App
knowledge belongs in plugins, skills, catalogs, or memory, not in core harness
conditionals.

## Computer Use

Computer use is one tool family inside the harness.

Accessibility is the primary source for actionable UI elements. Screenshots,
vision, OCR, and hover evidence can enrich the world model, labels, and layout,
but they must not authorize live input by themselves.

Element actions execute only after the harness validates:

- target focus
- permission policy
- element eligibility
- allowed action type
- rate limits
- safety class
- verification criteria

Models should choose semantic targets and tool calls. They should not
micromanage pixels. Coordinate input is fallback evidence only and must pass the
same guarded execution checks as other input.

## AppleScript And Scripts

AppleScript is a tool path, not a hardcoded helper path.

AppleScript generation gathers the resolved app, goal, entities, allowed
actions, and verification criteria, then passes that bounded request through a
model/script-generation boundary. It returns a script artifact for validation or
review. It does not execute the script.

AppleScript execution may run only a validated, generated, or user-reviewed
artifact through the guarded automation backend, with target app, permissions,
action metadata, and verification evidence attached.

App-specific AppleScript belongs in skill-local scripts or generated artifacts.
The guarded backend renders explicit `appleScript.source` or
`appleScript.template` metadata; it should not grow app-named script helpers.

Do not add app-named Swift helpers such as `musicPlaybackScript` or
`openFooScript`. If an app needs automation knowledge, put it in a skill,
plugin, catalog entry, generated artifact, or user-reviewed definition.

## Skills

Skills are reusable harness extensions. A skill can be registered directly or
discovered from configured roots by finding `SKILL.md` files. The skill
registry indexes:

- id
- name
- summary and description
- source kind
- instruction path
- tags
- provided tools
- scripts
- required permissions
- metadata

Skill lookup lets the planner find relevant instructions by structured task
need. Loading a skill adds selected instructions to bounded planning context.

Skills are shared infrastructure. They should be reusable by any future agent
or task, not private scratch memory for one run.

Built-in app skills live as resource skill packs under
`apps/Donkey/Sources/DonkeyRuntime/Resources/BuiltInSkills/`. They are loaded
through the same skill descriptor shape as user/plugin skills and compacted
before being sent to model boundaries.

## Skill Scripts

Skill packs may include generated scripts under a skill-local `scripts/`
directory. Supported script descriptors include AppleScript, shell/Bash,
Python, JavaScript, Swift, and future language types.

Each script descriptor records:

- id
- language
- purpose
- skill-relative path
- generator provenance
- validation status
- required permissions
- safety class
- metadata

Script generation, validation, and execution are separate steps. Generation
creates a reusable artifact through a model boundary and stores it as pending
validation. Validation records whether the script is allowed. Execution may run
only validated scripts through the appropriate guarded backend with normal
permission and verification gates.

A learned application skill can therefore carry instructions, app maps,
workflow recipes, evidence notes, and generated scripts together.

## Learning Applications

"Learn an application" is supported as a skill-producing harness task. The
generic built-in tools `application.learning.start`,
`application.learning.captureState`,
`application.learning.proposeExploration`, `application.learning.distill`, and
`application.learning.saveSkillPack` coordinate the flow: start a safe learning
draft, record bounded screenshot and Accessibility evidence, propose reversible
exploration candidates from technical Accessibility roles/actions, distill an
app profile and workflow recipes, and save a reusable skill pack.

For each meaningful state, the learner should gather:

- screenshot evidence
- Accessibility tree
- focused app/window metadata
- visible text
- actionable elements
- menus, buttons, fields, panels, and tabs
- navigation path
- what changed from the previous state

The learner should default to safe exploration: open menus, inspect tabs,
focus fields, navigate panels, and avoid destructive/send/purchase/save-overwrite
actions unless the user explicitly approves.

The reusable output should be distilled, not just raw captures:

- `SKILL.md` for human/model instructions
- structured app profile JSON
- workflow recipes
- generated scripts in `scripts/`
- verification rules
- safety notes
- optional redacted evidence artifacts

Validated generated scripts owned by the learned skill are copied into the
skill-local `scripts/` directory when the pack is saved. Future agents use the
learned app skill by searching for the relevant skill, loading its bounded
instructions, and then using any validated scripts or workflow tools exposed by
that skill.

## Intent Rules

Never infer semantic user intent by string matching raw user input. Do not add
phrase lists, prefixes, suffixes, regexes, app-name checks, greeting/help
classifiers, or natural-language command-text matching to decide what the user
wants.

Pass the turn through an LLM or another typed model/runtime boundary first. Once
structured output exists, deterministic code may validate typed fields, schema
values, tool names, permissions, app identifiers, filesystem paths,
Accessibility constants, and other non-semantic technical data.

## Verification

Use `swift test` from `apps/Donkey/`.

Generic harness tests should cover:

- tool registration and unknown-tool rejection
- permission stop/resume
- clarification stop/resume
- pause, resume, interrupt, cancel, complete, and fail-safe states
- multiple active tasks with isolated state
- one-tool-at-a-time execution loops
- skill registration, search, loading, and filesystem discovery
- script discovery, generation metadata, validation gates, and execution gates

Computer-use tests should cover app search, element retrieval, guarded element
actions, screenshot/Accessibility evidence boundaries, and verification failure
recovery.

## Source Entry Points

Start in:

- `apps/Donkey/Sources/DonkeyHarness/` for generic harness lifecycle, tool
  registry, skill discovery, and script descriptors.
- `apps/Donkey/Sources/DonkeyContracts/` for shared contracts that cross module
  boundaries.
- `apps/Donkey/Sources/DonkeyRuntime/` for guarded runtime execution,
  Accessibility, app/window observation, and input backends.
- `apps/Donkey/Sources/DonkeyAI/` for hosted model routing and adapters.
- `apps/Donkey/Sources/Donkey/` for pointer-prompt integration.

Tests live in `apps/Donkey/Tests/DonkeyRuntimeTests/`.
