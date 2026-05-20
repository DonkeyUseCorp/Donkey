# Donkey Architecture

This document is a compact map of Donkey's supported runtime architecture. The
source of truth for behavior and boundaries remains
[`docs/guides/minimal-run-coordinator.md`](guides/minimal-run-coordinator.md).

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
|  +----------------------+      +----------------------+              |         |
|  | Task Intent Resolver |<---->| Per-Task Coordinator |--------------+         |
|  | validated TaskIntent |      | lifecycle + policy   |                        |
|  +----------+-----------+      +----------+-----------+                        |
|             |                             |                                    |
|             v                             v                                    |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Local App Runner     |----->| Capture/Observation  |----->| Action Engine | |
|  | dry-run or guarded   |      | AX/window/screenshot |      | keyboard/AX   | |
|  +----------------------+      +----------------------+      +---------------+ |
|                                                                                |
+--------------------------------------------------------------------------------+
```

The app shell owns entrypoints, durable task threads, setup, and per-task runtime
coordination. Capture, observation, model sidecars, task adaptation, and input
execution stay behind narrow runtime boundaries.

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
|  | Core Data            |<-----| Task Events          |<-----| Agent Run     | |
|  | task/event/asset     |      | user/assistant/tool  |      | command path  | |
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
|  selected task command                                                         |
|             |                                                                  |
|             v                                                                  |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Task Context         |----->| Local LLM Parser     |----->| TaskIntent    | |
|  | command/events/assets|      | sidecar JSON schema  |      | validated     | |
|  +----------+-----------+      +----------------------+      +-------+-------+ |
|             |                                                        |         |
|             v                                                        v         |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Catalog Resolution   |----->| Local App Adapter    |----->| Task Run      | |
|  | app/task available   |      | steps + verification |      | per-task coord| |
|  +----------------------+      +----------+-----------+      +-------+-------+ |
|                                           |                          |         |
|                                           v                          v         |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Launch / Focus       |----->| Observation          |----->| World State   | |
|  | target app/window    |      | AX + metadata + UI   |      | typed compact | |
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

The hot path must keep working without a remote model call. Local model output is
validated into typed contracts before execution, controller output is semantic,
and the action engine is the only boundary allowed to issue guarded OS input.

## Local Stack And Model Sidecars

```text
+--------------------------------------------------------------------------------+
|                              Local Machine Stack                               |
+--------------------------------------------------------------------------------+
|                                                                                |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Donkey Swift Runtime |----->| JSON Sidecar Runner  |----->| Runtime Store | |
|  | contracts/controllers|      | stdin/stdout process |      | App Support   | |
|  +----------+-----------+      +----------+-----------+      +-------+-------+ |
|             |                             |                          |         |
|             |                             v                          |         |
|             |                  +----------------------+              |         |
|             |                  | App-Managed Registry |<-------------+         |
|             |                  | executable paths     |                        |
|             |                  +----------+-----------+                        |
|             |                             |                                    |
|             v                             v                                    |
|  +----------------------+      +----------------------+      +---------------+ |
|  | macOS Services       |      | Local Command LLM    |      | Parakeet ASR  | |
|  | AX/SCK/LaunchServices|      | TaskIntent JSON      |      | transcript    | |
|  +----------+-----------+      +----------------------+      +---------------+ |
|             |                                                                  |
|             v                                                                  |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Target Apps          |      | YOLO Segmentation    |      | UI Understand | |
|  | Weather/Music/docs   |      | bounded screenshots  |      | screenshot obs| |
|  +----------------------+      +----------------------+      +---------------+ |
|                                                                                |
+--------------------------------------------------------------------------------+
```

Runtime setup installs or validates sidecar packages after app install; model
weights are not bundled in `Donkey.app`. Developer environment variables can
override sidecar paths, while normal installs resolve through the app-managed
runtime registry under Application Support.

The supported setup boundary includes bundled runner packages, manifest,
checksum, and configured release-key signature validation, Application Support
registration, health checks, model-prep hooks, retryable first-run setup,
settings access, repair/remove lifecycle helpers, support status export, and
package-local Python wheelhouses built for the release target. The UI
understanding backend is a packaged Swift sidecar using Apple Vision, and the
command parser LLM currently uses Ollama as a documented local prerequisite.

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
|             |                  | Run Memory           |----->| Redaction     | |
|             |                  | bounded/source-linked|      | remote-bound  | |
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
and are validated, memory writes pass deterministic approval, and provider
failure leaves the fast local loop running on existing state.
