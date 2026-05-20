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
by a chat response, a local model classifier, deterministic parsing, or a
guarded runtime path.

Model calls live behind typed harness boundaries. Voice transcription is a local
model call before intake and produces a transcript turn. The local LLM call,
provider LLM call, memory helpers, and deterministic fallback each consume the
bounded context packet and return typed decisions or helper artifacts.
Observation models such as screenshot segmentation and UI understanding run
inside the local-task branch and produce observation evidence, not direct input
actions.

Routing outcomes carry a structured `AppHarnessDecision`. The decision names the
next supported harness action:
respond, ask for clarification, open review, run a local task, or no-op. This
keeps model-assisted routing in a typed decision space instead of treating free
text as an implicit action signal.

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
inspectable. Memory retrieval should use target/scope filters, relevance
thresholds, and prompt-character budgets before summaries are added.

Context compaction is typed and inspectable. Current turns, policy, active
target state, runtime capabilities, and trace identifiers are preserved first.
Transient retry/correction events are dropped before durable thread events,
and packet metadata records what was included, dropped, or truncated by item
kind.

## Routing Outcomes

Conversation is a first-class outcome. Greetings, "what can you do?", small
talk, and explanatory questions should stay in the task thread and get an
assistant response. These turns may update memory or teach the user about
available capabilities, but they should not create a failed local-app run.

Clarification is for actionable intent with missing required information. If
the user says "play music", the harness should ask what to play. If the user
says "fill this out" without a document or data source, it should ask for the
missing input or invite an upload. The prompt should name the missing detail
rather than using generic copy like "Need more detail".

Action execution is for validated, supported tasks. The local-model classifier
and deterministic fallback can produce a `TaskIntent`, but execution may only
continue after catalog validation confirms the target app/task, required
entities, app availability, and safety policy. Built-in examples such as
weather lookup, media playback, and document form-fill are benchmark definitions
inside this generic path, not separate architectures.

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
model can be told about this state, but the runner owns it.

Live input remains guarded. The action engine checks permission policy, target
focus, rate limits, hold duration, and backend evidence before issuing input.
The macOS keyboard and Accessibility backends are intentionally narrow. They
exist for validated local-app workflows, not arbitrary UI automation.

Observation prefers Accessibility and app/window metadata. Bounded screenshots
and local UI understanding are fallback observation context only; they do not
emit direct input actions. Captured screenshots, Accessibility snapshots, and
manual capture artifacts are trace evidence, not a general live vision loop.

The fast local path must keep working without remote model calls. Local sidecars
can classify actionable turns, transcribe voice, segment screenshots, or
summarize UI observations. Provider-backed planners and memory proposals remain
slow-path helpers and must fail without stopping local control on existing
validated state.

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
guide rather than becoming the guide.

## Source Entry Points

Start in `apps/Donkey/Sources/Donkey/` for pointer-prompt integration,
`apps/Donkey/Sources/DonkeyContracts/` for shared contracts,
`apps/Donkey/Sources/DonkeyRuntime/` for runtime execution and guardrails, and
`apps/Donkey/Sources/DonkeyAI/` for model routing and adapters. Tests live in
`apps/Donkey/Tests/DonkeyRuntimeTests/`.
