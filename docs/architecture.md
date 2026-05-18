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
|  | typed/voice command  |      | install runtimes     |      | smoke tools   | |
|  +----------+-----------+      +----------+-----------+      +-------+-------+ |
|             |                             |                          |         |
|             v                             v                          v         |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Command Intake       |      | Local Runtime Setup  |      | Manual Target | |
|  | text/transcript      |      | manifests/cache      |      | Capture       | |
|  +----------+-----------+      +----------+-----------+      +-------+-------+ |
|             |                             |                          |         |
|             v                             v                          v         |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Task Intent Resolver |<---->| Runtime Registry     |      | Artifact Store| |
|  | validated TaskIntent |      | sidecar executables  |      | traces/files  | |
|  +----------+-----------+      +----------------------+      +-------+-------+ |
|             |                                                        ^         |
|             v                                                        |         |
|  +----------------------+      +----------------------+      +-------+-------+ |
|  | RunCoordinator       |----->| Event Stream         |----->| Status/Reports| |
|  | lifecycle + policy   |      | assistant/tool/etc.  |      | latency/replay| |
|  +----------+-----------+      +----------------------+      +---------------+ |
|             |                                                                  |
|             v                                                                  |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Local App Runner     |----->| Capture/Observation  |----->| Action Engine | |
|  | dry-run or guarded   |      | AX/window/screenshot |      | keyboard/AX   | |
|  +----------------------+      +----------------------+      +---------------+ |
|                                                                                |
+--------------------------------------------------------------------------------+
```

The app shell owns user entrypoints and setup. `RunCoordinator` owns lifecycle,
event ordering, permission policy, bounded context assembly, and reflex trace
publication. Capture, observation, model sidecars, task adaptation, and input
execution stay behind narrow runtime boundaries.

## Fast Local Runloop

```text
+--------------------------------------------------------------------------------+
|                         Fast Local Navigation Hot Path                         |
+--------------------------------------------------------------------------------+
|                                                                                |
|  user command or transcript                                                    |
|             |                                                                  |
|             v                                                                  |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Task Definitions     |----->| Local LLM Parser     |----->| TaskIntent    | |
|  | built-in + JSON/JSONL|      | sidecar JSON schema  |      | validated     | |
|  +----------+-----------+      +----------------------+      +-------+-------+ |
|             |                                                        |         |
|             v                                                        v         |
|  +----------------------+      +----------------------+      +---------------+ |
|  | Catalog Resolution   |----->| Local App Adapter    |----->| Run Request   | |
|  | app/task available   |      | steps + verification |      | target + plan | |
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
