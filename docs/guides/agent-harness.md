# Agent Harness

## What It Is

The agent harness is Donkey's boundary between the user's conversation and the
systems that can act on the Mac. It owns the question: "What should this turn do
next?" Sometimes the answer is normal conversation. Sometimes it is a
clarifying question. Sometimes it is a reviewed plan. Sometimes it is a guarded
local-app action.

A task is not just an executable command. A task is a durable conversation
thread with user turns, assistant turns, assets, memory, trace ids, and optional
action runs attached to it. This matters because a user can say "hi", ask what
Donkey can do, upload a file, revise a previous request, approve a form-fill
plan, or ask Donkey to operate another app. Those are all valid task-thread
turns, but only some of them should touch the action runtime.

The harness makes that distinction before execution. Non-actionable turns should
produce assistant responses. Ambiguous actionable turns should ask for the
specific missing information. Validated actionable turns may enter the local-app
runner, review UI, planner, or action engine. A greeting or capability question
must not become a failed task card.

## How A Turn Flows

Every prompt submission, voice transcript, follow-up, and asset event enters the
same harness intake path. Intake first attaches the turn to the right durable
thread, records the event, and builds a compact context packet. From there the
harness routes the turn by meaning, not by the fact that text was submitted.

The normal flow is:

1. Receive a turn from the pointer prompt, voice transcription, file drop, or a
   task follow-up.
2. Attach it to an existing or new task thread and persist the user-visible
   event.
3. Build a bounded context packet for this decision.
4. Classify the turn as conversation, clarification, review, actionable intent,
   planning/recovery, memory, or no-op.
5. Produce a conversational response, ask for missing details, open review, or
   execute a validated action.
6. Persist assistant/tool/lifecycle events and update the notch with the thread
   state and any action state.

The harness loop looks like this:

```text
 pointer prompt / file drop / follow-up        voice audio
                  |                                |
                  v                                v
        +-------------------+         +--------------------------+
        | user-visible turn |         | local model call        |
        +-------------------+         | Parakeet transcription  |
                  |                   +--------------------------+
                  |                                |
                  |                         transcript turn
                  |                                |
                  +---------------+----------------+
                                  |
                                  v
                     +------------------------+
                     | intake + thread attach |
                     +------------------------+
                                  |
                                  v
                     +------------------------+
                     | bounded context packet |
                     +------------------------+
                                  |
          +-----------------------+-----------------------+
          |                       |                       |
          v                       v                       v
+--------------------+  +--------------------+  +----------------------+
| deterministic      |  | local LLM call     |  | provider LLM call    |
| parser/fallback    |  | intent/follow-up   |  | response/planner/    |
|                    |  | classifier         |  | memory proposals     |
+--------------------+  +--------------------+  +----------------------+
          |                       |                       |
          +-----------------------+-----------------------+
                                  |
                                  v
                     +------------------------+
                     | AppHarnessDecision     |
                     +------------------------+
                        |                    |
                        v                    v
          +-------------------------+  +------------------------+
          | respond / clarify /     |  | catalog validation     |
          | review / no-op          |  +------------------------+
          +-------------------------+             |
                        |                         v
                        |             +------------------------+
                        |             | observe target app     |
                        |             +------------------------+
                        |                         |
                        |                         v
                        |             +------------------------+
                        |             | local model calls      |
                        |             | YOLO screenshot seg    |
                        |             | UI understanding       |
                        |             +------------------------+
                        |                         |
                        |                         v
                        |             +------------------------+
                        |             | project, approve,      |
                        |             | execute, verify        |
                        |             +------------------------+
                        |                         |
                        +-------------+-----------+
                                      |
                                      v
                         +------------------------+
                         | persist events + notch |
                         +------------------------+
                                      |
                                      v
                                 next turn
```

The harness should make conversation feel continuous even when execution happens
inside the thread. The user should not need to know whether a turn was answered
by a chat response, a local model classifier, a typed runtime artifact, or a
guarded runtime path.

Model calls live behind typed harness boundaries. Voice transcription is a local
model call before intake and produces a transcript turn. The local LLM call,
provider LLM call, memory helpers, and explicit metadata helpers each consume
the bounded context packet and return typed decisions or helper artifacts.
Observation models such as screenshot segmentation and UI understanding run
inside the local-task branch and produce observation evidence, not direct input
actions. Any semantic user-intent distinction, including whether a turn is a
visual-only agent visualization request, belongs behind one of these typed model
or catalog boundaries.

Routing outcomes carry a structured `AppHarnessDecision`. The decision names the
next supported harness action:
respond, ask for clarification, open review, run a local task, or no-op. This
keeps model-assisted routing in a typed decision space instead of treating free
text as an implicit action signal.

## Intent Classification Rules

User intent must not be inferred with ad hoc phrase, prefix, suffix, substring,
or regex checks against natural-language command text. Donkey has local LLMs,
task definitions, runtime catalogs, and agent memory context for this job. Use them.
The fast classifier may know typed capability buckets such as task ids,
capability ids, agent memory entry kinds, and model output statuses. It must not
recover those buckets by reading natural-language words out of the user's
prompt.

Allowed deterministic checks are narrow primitives whose correctness does not
depend on open-ended language semantics: empty input, numeric-only arithmetic
expression extraction, exact schema validation, explicit metadata flags, and
bounded normalization of lookup text after a typed decision has already selected
a lookup path. These checks must stay generic and must not encode app-specific
or workflow-specific user phrasing.

Disallowed checks include code that decides a user's semantic intent from
phrases like "show me how", "within", "play", "open", or app names outside a
declared task definition or model output. If behavior depends on what the user
means, add or reuse a typed classifier/resolver and test it with structured
model output. Do not patch another string list.

Do not look for words inside user command strings to decide what the user wants.
This includes local deterministic parser fallbacks, command trigger arrays,
prefix/suffix tests, and conversation/greeting/help classifiers. A typed model
or explicit runtime artifact must produce the intent first. Exact string checks
remain acceptable for non-semantic technical validation such as JSON schema
fields, CLI arguments, AppleScript syntax/output validation, filesystem paths,
accessibility constants, colors, and safety metadata.

Generic local-item lookup must follow the same rule. Do not add static command
verb, lookup prefix, or lookup suffix arrays to guess that text means "open this
app/file/folder." A typed model or catalog artifact selects the local-item
lookup capability and extracts the requested item name; after that, the runtime
may normalize that item name and resolve it through agent memory, Spotlight, and
bounded filesystem lookup.

Agent action visualization is the canonical example. The harness may show an
animated overlay cursor after a normal local-app run emits an
`AgentVisualizationPlan`, or after a model-backed resolver returns the same plan
shape in `visualOnly` mode. It must not use hardcoded prompt prefixes to decide
that a turn is visualization-only, and it must not parse app names or goals out
of text with local string slicing.

## Context Engineering

The harness builds context deliberately for each job. It should never dump raw,
unbounded thread history into a model or runtime adapter. Context packets should
be compact, source-linked, and explicit about what is known, what is missing,
what can be acted on, and what policies apply.

A useful context packet includes the current turn, a bounded summary of recent
thread events, relevant assets, active action state, selected app/window facts
when available, task definitions and supported capabilities, retrieved memory,
permission policy, safety state, and trace ids. The packet should be shaped for
the consumer: conversation response, intent classification, planner hint,
review-plan creation, memory retrieval, observation, and recovery do not need
the same fields.

Remote-bound context must be redacted before provider calls. Local-only context
can include richer app and observation facts, but should still stay bounded and
inspectable. Memory retrieval should use target/scope/kind filters, FTS/vector
relevance thresholds, and prompt-character budgets before summaries are added.

Context compaction is typed and inspectable. Current turns, policy, active
target state, runtime capabilities, and trace identifiers are preserved first.
Transient retry/correction events are dropped before durable thread events,
and packet metadata records what was included, dropped, or truncated by item
kind.

## Routing Outcomes

Conversation is a first-class outcome. Turns that do not produce a typed local
task intent stay in the task thread and get an assistant response instead of a
failed local-app run. Conversation classification may be model-backed or derived
from explicit runtime/model statuses, but it must not use greeting/help/small
talk phrase lists.

Clarification is for typed actionable intent with missing required information.
When the model returns a supported task but marks a required entity as missing,
the harness should ask for that exact entity or invite an upload. The prompt
should name the missing detail rather than using generic copy like "Need more
detail".

Action execution is for validated, supported tasks. The fast turn classifier can
answer narrow non-semantic turns such as numeric arithmetic; otherwise the local
model classifier or explicit runtime metadata produces a `TaskIntent`. Execution
may only continue after catalog validation confirms the target app/task,
required entities, app availability, and safety policy. The default runtime
capabilities are generic local-item open plus generic model-planned local-app
interaction; the latter materializes a transient task definition from an
allowlisted typed `actionPlan` before execution. Weather lookup, media
playback, and document form-fill are benchmark fixtures for tests and replay
evaluation, not runtime defaults. Runtime defaults come from the SQLite-backed
agent memory store, which is seeded with generic capabilities and enriched by
model-generated or user-reviewed task definition files.

Review is required when the harness can propose work but should not perform it
blindly. Document form-fill is the main supported example: Donkey can inspect
fields and propose mappings, but only user-approved fields are sent to guarded
Accessibility execution.

Planning and recovery are advisory. Slow planner output can help with app
knowledge lookup or recovery, but planner text must not become direct input.
Planner hints expire, validate against known actions, and remain separate from
task-intent parsing.

## Execution Boundary

The harness is allowed to coordinate execution, but it should not bypass the
runtime safety model. Local-app work flows through typed contracts, catalog
resolution, observation, dry-run projection, guardrails, and verification before
or during live control.

Local-app workflow progress is tracked outside prompt/context text. Each run
records typed stage state for intent parsing, task/app resolution, observation,
dry-run projection, approval/review, guarded execution, and verification. The
runner can derive projected agent visualization steps before live execution and
verified visualization steps from runtime state plus action traces. The model
can be told about this state, but the runner owns it.

Live input remains guarded. The action engine checks permission policy, target
focus, rate limits, hold duration, and backend evidence before issuing input.
The macOS AppleScript, keyboard, and Accessibility backends are intentionally
narrow. They exist for validated local-app workflows, not arbitrary UI
automation. Prefer app-native AppleScript for scriptable app tasks before
falling back to Accessibility or keyboard input. AppleScript commands may be
generated from task metadata or compact model-provided source/templates, but
they still run only after catalog validation and through the guarded controller
backend.

App automation scripts must be generated artifacts, not product code fixtures.
Do not add hardcoded app-specific AppleScript bodies, UI-scripting sequences, or
workflow scripts to Swift as static strings. The harness may keep generic
rendering/execution utilities such as string escaping, template interpolation,
schema validation, AppleScript syntax/language validation, and guarded backend
dispatch. The actual app-control script for a task must come from a typed
model/script-generation step, agent memory metadata, or a user-reviewed task
definition, and it must be logged with the model/schema/action metadata that
produced it.

If an app task needs AppleScript, the supported shape is: classify the task,
resolve the target app and entities, ask the model or task-definition layer for
a bounded script or template, validate that it matches the resolved task and
allowed backend, then execute it through the AppleScript backend. Adding a
`musicPlaybackScript`, `openFooScript`, or similar app-named helper is a harness
bug, even if the script happens to work on one machine.

Observation prefers Accessibility and app/window metadata. Bounded screenshots
and local UI understanding are fallback observation context only; they do not
emit direct input actions. Captured screenshots, Accessibility snapshots, and
manual capture artifacts are trace evidence, not a general live vision loop.
Verification and screenshot fallback behavior should be derived from task
metadata and runtime item metadata, not one-off branches for individual apps.

The fast local path must keep working without remote model calls. Local sidecars
can classify actionable turns, transcribe voice, segment screenshots, or
summarize UI observations. Provider-backed planners and memory proposals remain
slow-path helpers that write through deterministic approval into agent memory
and must fail without stopping local control on existing validated state.

Local model work that shares the same runtime capacity should enter a priority
worker. Interactive task-intent parsing runs at user-interactive priority and
can cooperatively preempt lower-priority planner, memory, or replay jobs.

## State And Observability

Task-thread state and action-run state are related but distinct. A thread can be
chatting, waiting for clarification, waiting for review, running an action,
completed, or failed. The notch should communicate that distinction so normal
conversation does not look like a broken command.

The coordinator owns lifecycle and event ordering for action runs. It records
assistant, tool, lifecycle, and reflex events; handles start, pause, resume,
completion, abort, timeout, and failure; and marks aborts/timeouts that require
held-input release. Run artifacts, screenshots, Accessibility captures, latency
reports, memory records, and model-call traces should remain source-linked and
inspectable.

Latency claims must come from monotonic trace data. Provider calls, planner
work, and slow recovery should not be counted as reflex-loop latency unless they
actually block that path.

## Verification

Use `swift test` from `apps/Donkey/` for the supported runtime and harness
coverage.

Harness tests should prove that non-actionable turns receive conversational
responses, ambiguous actionable turns ask specific clarification questions,
validated actions still run through catalog and guardrail checks, follow-ups get
the right thread context, and context packets stay bounded and redacted where
needed.

Runtime tests should continue covering coordinator lifecycle ordering, event
persistence, task-intent validation, local-app catalog resolution, observation,
Accessibility control discovery, guarded input, review-first document form-fill,
model routing, memory retrieval, redaction, latency reports, artifacts, window
resolution, and manual capture.

Manual smoke checks remain useful for window enumeration, manual capture, local
runtime setup/status, and dry-run latency reports, but they should support the
documented behavior rather than becoming the behavior definition.

## Source Entry Points

Start in `apps/Donkey/Sources/Donkey/` for pointer-prompt integration,
`apps/Donkey/Sources/DonkeyContracts/` for shared contracts,
`apps/Donkey/Sources/DonkeyRuntime/` for runtime execution and guardrails, and
`apps/Donkey/Sources/DonkeyAI/` for model routing and adapters. Tests live in
`apps/Donkey/Tests/DonkeyRuntimeTests/`.
