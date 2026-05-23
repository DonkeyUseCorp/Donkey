# Donkey Architecture

This document is a compact map of Donkey's supported runtime architecture. The
source of truth for behavior and boundaries remains
[`docs/guides/agent-harness.md`](guides/agent-harness.md).

## App-Level Components

```text
+--------------------------------------------------------------------------------+
|                                  Donkey.app                                    |
|                                                                                |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Pointer Prompt UI    |      | Runtime Setup UI     |      | Debug CLI     | |
|  | text/voice/assets    |      | install runtimes     |      | smoke tools   | |
|  +----------+-----------+      +----------+-----------+      +-------+-------+ |
|             |                             |                          |         |
|             v                             v                          v         |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Task Thread Intake   |      | Local Runtime Setup  |      | Manual Target | |
|  | route + persist      |      | manifests/cache      |      | Capture       | |
|  +----------+-----------+      +----------+-----------+      +-------+-------+ |
|             |                             |                          |         |
|             v                             v                          v         |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Follow-up Resolver   |<---->| Runtime Registry     |      | Artifact Store| |
|  | recent task match    |      | sidecar executables  |      | traces/files  | |
|  +----------+-----------+      +----------------------+      +-------+-------+ |
|             |                                                        ^         |
|             v                                                        |         |
|  +----------------------+      +----------------------+      +-------+-------+ |
|  | Core Data Task Store |----->| Notch Task List      |----->| Status/Reports| |
|  | tasks/events/assets  |      | recent threads       |      | latency/replay| |
|  +----------+-----------+      +----------------------+      +-------+-------+ |
|             |                                                        ^         |
|             v                                                        |         |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Agent Harness        |<---->| Agent Memory Store   |<---->| Per-Task Coord | |
|  | context + routing    |      | SQLite FTS/vector    |      | lifecycle     | |
|  +----------+-----------+      +----------+-----------+      +-------+-------+ |
|             |                             |                          |         |
|             v                             v                          v         |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Local App Runner     |----->| Capture/Observation  |----->| Action Engine | |
|  | dry-run or guarded   |      | AX/window/screenshot |      | keyboard/AX   | |
|  +----------------------+      +----------------------+      +---------------+ |
|                                                                                |
+--------------------------------------------------------------------------------+
```

The app shell owns entrypoints, durable task threads, setup, shared agent
memory, and per-task runtime coordination. Capture, observation, hosted model
adapters, task adaptation, and input execution stay behind narrow runtime
boundaries.

## Pointer Prompt Task Threads

```text
+--------------------------------------------------------------------------------+
|                              Durable Task Threads                               |
+--------------------------------------------------------------------------------+
|                                                                                |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Cmd-Cmd Input        |      | Notch Composer       |      | File Drop     | |
|  | text/voice           |      | follow-up text       |      | collapsed ok  | |
|  +----------+-----------+      +----------+-----------+      +-------+-------+ |
|             |                             |                          |         |
|             +-------------+---------------+                          |         |
|                           |                                          |         |
|                           v                                          v         |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Recent Tasks         |----->| Follow-up LLM        |----->| Task Select   | |
|  | updatedAt order      |      | match or new         |      | existing/new  | |
|  +----------+-----------+      +----------------------+      +-------+-------+ |
|             ^                                                        |         |
|             |                                                        v         |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Core Data            |<-----| Task Events          |<-----| Harness Turn  | |
|  | task/event/asset     |      | user/assistant/tool  |      | chat/action   | |
|  +----------+-----------+      +----------------------+      +-------+-------+ |
|             ^                                                        |         |
|             |                                                        v         |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Asset Files          |      | Coordinator Registry |----->| RunCoordinator| |
|  | App Support          |      | taskID -> run        |      | pause/resume  | |
|  +----------------------+      +----------------------+      +---------------+ |
|                                                                                |
+--------------------------------------------------------------------------------+
```

## Fast Local Runloop

```text
+--------------------------------------------------------------------------------+
|                         Fast Local Navigation Hot Path                         |
+--------------------------------------------------------------------------------+
|                                                                                |
|  actionable harness turn                                                       |
|             |                                                                  |
|             v                                                                  |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Harness Context      |----->| Local LLM Parser     |----->| TaskIntent    | |
|  | turn/events/assets   |      | sidecar JSON schema  |      | validated     | |
|  +----------+-----------+      +----------------------+      +-------+-------+ |
|             |                                                        |         |
|             v                                                        v         |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Agent Memory         |----->| Catalog Resolution   |----->| Local App     | |
|  | task defs/local item |      | app/task available   |      | Adapter       | |
|  +----------+-----------+      +----------------------+      +-------+-------+ |
|             |                                                        |         |
|             v                                                        v         |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Launch / Focus       |----->| Observation          |----->| Task Run      | |
|  | target app/window    |      | AX + metadata + UI   |      | per-task coord| |
|  +----------------------+      +----------+-----------+      +-------+-------+ |
|                                           |                          |         |
|                                           v                          v         |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Local Item Validate  |----->| World State          |----->| Reflex Trace  | |
|  | path/bundle exists   |      | typed compact        |      | source-linked | |
|  +----------------------+      +----------+-----------+      +-------+-------+ |
|                                           |                          |         |
|                                           v                          v         |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Reflex Frame Source  |----->| Perception Projector |----->| Controller    | |
|  | latest frame wins    |      | typed affordances    |      | semantic act  | |
|  +----------------------+      +----------------------+      +-------+-------+ |
|                                                                      |         |
|                                                                      v         |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Action Projection    |----->| Guardrails           |----->| Input Backend | |
|  | dry-run or live      |      | policy/focus/rate    |      | keyboard/AX   | |
|  +----------+-----------+      +----------------------+      +-------+-------+ |
|             |                                                        |         |
|             v                                                        v         |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Reflex Trace         |----->| Latency Report       |<-----| Verification  | |
|  | monotonic timings    |      | p50/p95/p99          |      | visible text  | |
|  +----------------------+      +----------------------+      +---------------+ |
|                                                                                |
+--------------------------------------------------------------------------------+
```

Every prompt turn enters the agent harness as conversation first. The harness
builds bounded context from thread history, assets, target state, memory,
runtime capabilities, policy, and trace ids, then routes the turn to
conversation, clarification, review, planning, or action execution. The hot path
must keep working without a remote model call. Local model output is validated
into typed contracts before execution, controller output is semantic, and the
action engine is the only boundary allowed to issue guarded OS input.

## Agent Memory System

```text
+--------------------------------------------------------------------------------+
|                              Agent Memory Store                                |
+--------------------------------------------------------------------------------+
|                                                                                |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Runtime Writes       |----->| Approval / Validate  |----->| SQLite Store  | |
|  | lookup/task/provider |      | source/privacy/ttl   |      | records       | |
|  +----------+-----------+      +----------------------+      +-------+-------+ |
|             |                                                        |         |
|             v                                                        v         |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Negative Lookups     |      | FTS5 Index           |<-----| Vector Blobs  | |
|  | expiry required      |      | lexical candidates   |      | Float32 local | |
|  +----------------------+      +----------+-----------+      +-------+-------+ |
|                                           |                          |         |
|                                           v                          v         |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Scoped Query         |----->| Rank + Budget        |----->| Harness Hints | |
|  | target/kind/text     |      | FTS/vector/recency   |      | bounded text  | |
|  +----------+-----------+      +----------------------+      +-------+-------+ |
|             |                                                        |         |
|             v                                                        v         |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Local Item Check     |      | Task Definitions     |      | JSONL Export  | |
|  | path/bundle exists   |      | generated/reviewed   |      | debug only    | |
|  +----------------------+      +----------------------+      +---------------+ |
|                                                                                |
+--------------------------------------------------------------------------------+
```

Agent memory is the durable store for local item records, negative lookups,
runtime task definitions, target facts, user instructions, safety stops, and
workflow memory. SQLite is the source of truth; JSONL is only an explicit export
format for support and debugging. Retrieval always applies scope/kind filters,
prompt budgets, and availability validation before a record influences planning
or execution.

## Local Stack And Hosted Models

```text
+--------------------------------------------------------------------------------+
|                              Local Machine Stack                               |
+--------------------------------------------------------------------------------+
|                                                                                |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Donkey Swift Runtime |----->| Donkey Backend Proxy |----->| Hosted Models | |
|  | contracts/controllers|      | typed HTTPS requests |      | providers     | |
|  +----------+-----------+      +----------+-----------+      +-------+-------+ |
|             |                             |                          |         |
|             |                             v                          |         |
|             |                  +----------------------+              |         |
|             |                  | Provider Config      |<-------------+         |
|             |                  | model selection      |                        |
|             |                  +----------+-----------+                        |
|             |                             |                                    |
|             v                             v                                    |
|  +----------------------+      +----------------------+      +---------------+ |
|  | macOS Services       |      | TaskIntent JSON      |      | Voice Input   | |
|  | AX/SCK/LaunchServices|      | structured outputs   |      | transcription | |
|  +----------+-----------+      +----------------------+      +---------------+ |
|             |                                                                  |
|             v                                                                  |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Target Apps          |      | Computer Use         |      | UI Context    | |
|  | Weather/Music/docs   |      | hosted decisions     |      | evidence      | |
|  +----------------------+      +----------------------+      +---------------+ |
|                                                                                |
+--------------------------------------------------------------------------------+
```

Runtime setup does not install model sidecars or model weights after app
install. Model-backed behavior uses authenticated backend routes; the backend
owns provider credentials, provider selection, and concrete model selection.
The Mac app keeps local execution, permissions, Accessibility, screenshot
capture, and target-app control, but not local model hosting.
Gemini computer-use support is exposed as two backend tool registrations:
`donkey_gemini_browser_interaction` for browser control and
`donkey_gemini_mac_desktop_interaction` for guarded macOS desktop control.

## Slower AI Harness

```text
+--------------------------------------------------------------------------------+
|                         Slow Models And Advisory Sidecars                      |
+--------------------------------------------------------------------------------+
|                                                                                |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Reflex Loop          |----->| Slow Planner Trigger |----->| Snapshot      | |
|  | does not await model |      | scene/failure/etc.   |      | compact state | |
|  +----------+-----------+      +----------------------+      +-------+-------+ |
|             |                                                        |         |
|             |                                                        v         |
|             |                  +----------------------+      +---------------+ |
|             |                  | Agent Memory         |----->| Redaction     | |
|             |                  | SQLite FTS/vector    |      | remote-bound  | |
|             |                  +----------+-----------+      +-------+-------+ |
|             |                             |                          |         |
|             |                             v                          v         |
|             |                  +----------------------+      +---------------+ |
|             |                  | AI Model Router      |----->| Providers     | |
|             |                  | role/privacy/risk    |      | local/online  | |
|             |                  +----------+-----------+      +-------+-------+ |
|             |                             |                          |         |
|             |                             v                          v         |
|             |                  +----------------------+      +---------------+ |
|             |                  | Planner Hint         |<-----| Model Trace   | |
|             |                  | structured JSON      |      | latency/cost  | |
|             |                  +----------+-----------+      +---------------+ |
|             |                             |                                    |
|             v                             v                                    |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Existing Controller  |<-----| Hint Validator/Bus   |----->| Replay/Eval   | |
|  | can run without hint |      | expiry + safety      |      | promotion     | |
|  +----------------------+      +----------------------+      +---------------+ |
|                                                                                |
+--------------------------------------------------------------------------------+
```

Slow models can help with ambiguous commands, recovery, planner hints, memory
proposals, and observability. Their outputs remain advisory: planner hints expire
and are validated, memory writes pass deterministic approval into agent memory,
and provider failure leaves the fast local loop running on existing state.
