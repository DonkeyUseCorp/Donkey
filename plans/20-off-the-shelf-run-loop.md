# Off-The-Shelf Run Loop

> Active status: not complete. The current repo supports metadata-only local-navigation dry-run scaffolding and guarded live-action smoke, but not a live fast-navigation agent for a concrete command such as "show me the weather for SF".

## Goal

Build the first fast local navigation agent from existing system components instead of custom model work.

The first product proof is a local Weather lookup navigation benchmark. Donkey should interpret a natural command, use local macOS navigation to open or focus Weather, type/search for San Francisco, verify the app is showing the requested place, and leave the result visible. It should feel faster than manual app navigation or a chat assistant because most work is local and deterministic.

Fast navigation is the focus across apps and games. Use Accessibility, app/window metadata, LaunchServices, keyboard input, screenshot/OCR fallback, open-vocabulary detectors, segmentation, templates, and classical CV as swappable navigation signals. Start with the cheapest local signal that can reliably move the target toward the requested state.

## Target Shape

```text
User Command
  -> Intent Parser
  -> Task Adapter
  -> App Launch / Focus
  -> Accessibility / Window Metadata / Screenshot Fallback
  -> Task State
  -> Deterministic UI Controller
  -> Action Engine
  -> Keyboard / Mouse / Accessibility Action
  -> Result Verification

Reasoning LLM
  <-> Ambiguous Intent / UI Understanding / Memory / Recovery
```

The hot path is local and bounded. A small model can help interpret unusual phrasing, but app navigation and action timing come from deterministic logic over structured state.

## Core Rule

Do not build a custom model pipeline for the first version.

The first version should prove:

- command-to-intent parsing is reliable for common tasks
- macOS app launch/focus is reliable
- Accessibility/window metadata can extract useful app state
- screenshot/OCR fallback is available only when needed
- state is compact and timestamped
- controller rules can act on that state
- guarded live input can type/search safely
- result verification can confirm the requested target
- latency is measured end to end
- the LLM can help with ambiguous phrasing and recovery without blocking local navigation

## Hot-Path Components

Use existing, swappable components:

- deterministic intent parser for common local commands
- small local model or planner hint only for ambiguous command parsing
- target/task adapters for app-specific workflows
- LaunchServices or Workspace app launch/focus
- Accessibility snapshots/actions for app UI state and controls
- keyboard/mouse input behind guardrails
- template matching or OCR for UI fallback
- YOLO-family detector for boxes, UI elements, enemies, objects, and markers
- SAM / SAM2 / MobileSAM / FastSAM for masks when boxes are not enough
- OCR for text, labels, and menus when Accessibility is insufficient
- color/edge/motion heuristics for simple fast signals
- deterministic state machines for action decisions
- LLM planner only for slow hints and recovery

Avoid:

- custom policy models
- custom action models
- custom neural networks
- full LLM decision-making every frame
- Ollama or any chat LLM in the per-frame action path
- remote model calls for common app-command execution
- Python pixel loops in the hot path
- generic agent frameworks around every frame

## Runtime Stack

Keep the runtime optimized even when the models are off the shelf.

Preferred inference paths:

- ONNX Runtime as the portable boundary
- TensorRT on NVIDIA when it wins measured p95 latency
- CUDA graphs for fixed-shape repeated inference when launch overhead matters
- DirectML or WinML as a broad Windows fallback
- Core ML / Metal on Apple hardware
- CPU only for tiny templates, OCR snippets, or very small models

Runtime rules:

- keep model inputs fixed-size when possible
- warm every model before live control starts
- preallocate buffers
- avoid PNG/JPEG encode/decode in the hot loop
- drop stale frames
- cap queue sizes at 1 in the reflex path
- benchmark each component separately and together

## Product-Grade Run Loop

Wrap the low-latency loop in an OpenClaw-inspired runtime shell, but do not make Donkey depend on OpenClaw, Pi, or a generic agent framework in the hot path.

The product loop should look like:

```text
intake / local intent parse
  -> session queue
  -> context assembly
  -> task adapter selection
  -> local app observation
  -> deterministic controller
  -> tool / action execution
  -> result verification
  -> streaming events
  -> transcript / trace persistence
  -> compaction / recovery
```

The runtime shell owns coordination. It loads target adapters and skills, resolves model/auth/runtime profiles, subscribes to model/tool/reflex events, enforces queue sizes and deadlines, applies tool permission policy, and bridges events back to UI or client streams.

The runtime shell does not own app-specific workflow internals, perception logic, controller policy internals, or direct OS input. Those stay behind explicit intent, task-adapter, capture/perception, controller, and action-engine interfaces.

### First Benchmark: Weather Lookup

The first supported benchmark is:

```text
"show me the weather for SF"
  -> weather_lookup(city: "San Francisco")
  -> open/focus Weather
  -> search/select San Francisco
  -> verify displayed location
```

The first navigation adapter should support:

- deterministic alias expansion for common city shorthand such as `SF`
- dry-run trace output before live input
- app launch/focus through a narrow macOS app-control boundary
- observation through Accessibility first, window metadata second, screenshot/OCR fallback last
- guarded text entry into the Weather search field
- verification that the visible Weather location matches San Francisco
- terminal result states: completed, needs-user-review, failed-safe, timed-out

### Event Bridge

Publish a small set of typed event streams:

- `assistant`: user-visible reasoning, recovery notes, explanations, summaries
- `tool`: capture, perception, controller, action, Accessibility, model, and persistence calls
- `lifecycle`: run started, paused, resumed, aborted, timed out, completed
- `reflex`: frame, state, and action trace events, sampled or summarized to avoid hot-path overhead

All event envelopes should include trace ids where possible. Reflex events must be cheap to emit and safe to drop or sample when the loop is under pressure.

### Run Coordination Responsibilities

The coordinator should provide the product-grade parts around the loop:

- session queue with latest-request-wins behavior for live control
- run lifecycle state: idle, starting, running, paused, stopping, completed, failed
- tool permission policy for capture, Accessibility, model calls, and input actions
- transcript and trace persistence with a single writer or explicit append lock
- context compaction before slow planner calls
- streaming event publication for UI/client observers
- abort and timeout handling that releases held input and closes streams
- sandbox/focus guard for risky tools and OS input
- bounded queues, deadlines, and stale-frame drops

### Conceptual Runtime Shape

This pseudocode is conceptual. It describes coordination boundaries, not the exact Swift API.

```swift
while run.isActive {
    let ticket = await sessionQueue.nextLatest()

    let context = await contextAssembler.build(
        session: ticket.session,
        latestWorldState: stateStore.latest(),
        transcriptSummary: transcript.compactedSummary(),
        activeHints: hintStore.validHints()
    )

    let plannerResult = await planner.maybeGenerate(
        context: context,
        timeout: policy.plannerTimeout
    )

    await hintStore.publishValidated(plannerResult.hints)
    await stream.publish(plannerResult.events)

    while let frame = await frameBuffer.latestIfFresh() {
        let state = await perception.update(frame)
        let action = controller.decide(state, hintStore.validHints())

        guard await permissionPolicy.allows(action),
              await focusGuard.targetIsSafe()
        else {
            await lifecycle.pause(reason: .unsafeActionSurface)
            break
        }

        let result = await actionEngine.execute(action)
        await traceStore.append(frame, state, action, result)
        await stream.publishReflexSample(frame, state, action, result)
    }
}
```

Separate the loops in implementation:

- reflex loop: latest-frame-wins capture, local perception, deterministic controller, bounded action execution
- planner loop: context assembly, model call, validated planner hints, memory updates
- tool/action loop: permission checks, sandbox/focus guard, execution, trace persistence

Remote LLM and chat-style local LLM work belongs in the planner loop. It must never be required for reflex ticks or direct input.

### Interfaces To Define

Define these contracts before the first production coordinator implementation:

- `RunSession`: user goal, target id, runtime profile, permission scope, lifecycle state
- `RunEvent`: assistant/tool/lifecycle/reflex event envelope with trace ids
- `TaskIntent`: parsed local app task, normalized entities, confidence, parser source
- `TaskAdapter`: app-specific observation, action selection, verification, and recovery hooks
- `ToolCallPolicy`: allow, deny, or ask rules for capture, Accessibility, model, and input actions
- `TranscriptStore` / `TraceStore`: append-only persistence with a single writer or explicit lock
- `ContextAssembler`: compact planner context from world state, traces, memory, screenshots, and user goal
- `RunCoordinator`: queueing, cancellation, timeouts, event bridging, and lifecycle ownership

## Platform Defaults

### Windows

Best default for raw desktop game performance:

```text
DXGI Desktop Duplication
  -> crop on GPU or with minimal copy
  -> ONNX Runtime / TensorRT / DirectML
  -> native input backend
```

Use TensorRT first on NVIDIA if the model exports cleanly and p95 latency improves. Use DirectML/WinML when broader GPU support matters more than peak NVIDIA performance.

### macOS

Best default for local app task control:

```text
Natural command
  -> deterministic/local intent parser
  -> NSWorkspace/LaunchServices app activation
  -> Accessibility tree/action when trusted
  -> guarded keyboard/mouse fallback
  -> ScreenCaptureKit/OCR only for missing UI facts
```

Use Accessibility for window bounds, focus checks, controls, dialogs, and setup flows. Use screenshot perception only when the app does not expose the needed state through Accessibility.

## Vision Options

### Detector First

For later visual targets, start with a detector when the target state can be represented as objects.

Good jobs:

- enemies
- obstacles
- buttons
- collectibles
- health bars
- hit markers
- lane markers
- minimap markers

Use current Ultralytics YOLO-family nano/small models as candidates. The exact model should be selected by export support, license, latency, and whether the built-in labels are useful. As of current Ultralytics docs, YOLO26 is the newest line, YOLO11 is a stable modern line, and YOLOv8 remains widely supported.

### Segment Anything When Needed

Use SAM-style segmentation when object boundaries matter or the scene is too irregular for boxes.

Candidate options:

- SAM / SAM2 for high-quality masks and video/image segmentation
- MobileSAM for lighter local segmentation
- FastSAM for faster approximate masks
- Ultralytics SAM integrations when they simplify wiring

Use segmentation sparingly in the hot loop. It is often better as:

- slow-path scene understanding
- mask proposal for a region of interest
- setup/calibration helper
- fallback when detection is ambiguous

### OCR And UI Parsing

Use OCR for:

- menus
- labels
- scores
- inventory text
- quest text
- countdowns

OCR should usually run on cropped regions, not the full frame.

### Templates And Classical CV

Use simple methods when they work:

- template matching for known buttons/icons
- color thresholding for health/resource bars
- optical flow or frame differencing for motion
- edge/shape heuristics for simple lanes and obstacles
- DOM parsing when the target is web-based

These are often faster and easier to debug than a model.

## Task State

Convert all observation outputs into a compact state object:

```text
state_id
frame_id
timestamp
target_id
task_intent_id
app_id
scene_type
objects
masks
text
ui_flags
action_affordances
confidence
source_ages
planner_hint_id
```

Rules:

- include confidence and age for every signal
- keep coordinate spaces explicit
- mark stale fields instead of silently using them
- do not expose detector tensors or raw masks directly to the controller
- prefer task-specific state over generic scene captions

For the Weather target, state should include:

```text
app_running
app_frontmost
search_field_available
search_text
selected_location
visible_location
weather_result_visible
confidence
verification_reason
```

## Controller

Use deterministic logic over task state:

```text
Task State
  -> Policy Selector
  -> Rule / State Machine
  -> Semantic Action
  -> Calibrated Input
```

Examples:

- Weather not running -> launch app
- Weather running but not focused -> focus app
- search field visible and empty -> type normalized city
- matching location suggestion visible -> select suggestion
- visible location matches normalized city -> complete
- obstacle on left lane -> move center/right
- button visible and safe -> tap button center
- health low -> request planner recovery hint
- menu state unknown -> pause and ask LLM to classify snapshot
- target box center offset -> move/click toward center
- countdown text appears -> wait or prepare action

The controller should be boring, inspectable, and traceable.

## LLM Role

Use LLMs for:

- interpreting ambiguous commands when deterministic intent parsing is insufficient
- interpreting unfamiliar screens
- choosing objectives
- explaining failures
- deciding which detector/OCR/template signals matter
- suggesting recovery steps
- summarizing memory
- reading slow-path screenshots or UI snapshots
- producing structured planner hints

Do not use LLMs for:

- launching apps
- typing ordinary search text
- clicking known controls
- aiming every frame
- dodge timing
- tap/swipe timing
- continuous movement
- direct OS input

LLM output must become validated hints, not direct actions.

## First Supported Benchmark Recommendation

Pick one navigation scenario with a visible, verifiable end state.

The first benchmark is Weather lookup:

- command: "show me the weather for SF"
- normalized intent: `weather_lookup(city: "San Francisco")`
- target app: Weather
- success: Weather is frontmost and visibly showing San Francisco weather

Good follow-on tasks:

- fast game/menu navigation to a known screen
- open Calendar to a named date
- search Mail for a sender
- create a short Notes note
- open a browser tab to a known site
- navigate a repeated game menu

Suggested first stack:

```text
Intent: deterministic parser with local-model fallback for ambiguity
App control: NSWorkspace/LaunchServices activation
Observation: Accessibility snapshot first, screenshot/OCR fallback
Rules: deterministic Weather task state machine
Input: guarded keyboard/mouse or Accessibility action backend
Reasoning: local/online planner only for recovery or ambiguity
Runtime: native Swift coordinator and trace pipeline
```

## Rollout

1. Define `TaskIntent` for `weather_lookup`.
2. Add deterministic parsing for "weather", city names, and common aliases such as `SF`.
3. Define Weather task-state fields and terminal states.
4. Add a Weather navigation adapter with dry-run semantic actions.
5. Add app launch/focus action commands and guardrails.
6. Add guarded text-entry and submit/select commands.
7. Add Accessibility observation for Weather controls and visible location.
8. Add screenshot/OCR fallback only where Accessibility is insufficient.
9. Add result verification for San Francisco.
10. Add command-to-result latency report and manual baseline comparison.
11. Add optional slow planner recovery only after deterministic execution works.
12. Keep game/vision adapters as follow-on targets using the same contracts.

## Acceptance Criteria

- No custom model work is required.
- The hot loop can run with the LLM disabled.
- The Weather lookup navigation benchmark can run without a remote model call.
- Every perception component is swappable.
- Every action is explainable from state, rule, and trace id.
- p95 local navigation/action latency stays under the target budget.
- command-to-result latency is measured against a manual baseline.
- LLM output is validated before it changes controller configuration.
- Segmentation and OCR are cropped and measured before live use.
- The runtime coordinator can start, pause, abort, timeout, and complete a run.
- Abort releases held input and publishes a terminal lifecycle event.
- Session queue drops stale live-control work instead of building backlog.
- Permission policy can deny unsafe input before action execution.
- Transcript and trace writes stay ordered under concurrent model/tool/reflex events.
- Context compaction keeps planner input bounded while preserving the latest goal, state, failures, and valid hints.

## Current Supported Slice

The runtime foundation now supports a product-shaped local-navigation slice of the off-the-shelf loop:

- typed reflex trace records with capture, preprocessing, model, perception, state, controller, action, and input timestamps
- bounded target-window frame capture for dry-run frames without PNG/JPEG hot-path encoding
- cheap metadata perception and swappable world-state projection
- recorded off-the-shelf detector/template/OCR/segmentation evidence projection with crop ids, model/component ids, confidence, coordinate spaces, and measured preprocessing/model latency
- loop-integrated metadata-only local-navigation dry-run selection with optional browser-tab metadata
- latest-frame-wins queue depth 1 with dropped-frame counting
- p50/p95/p99 latency reports across capture, preprocess, model, perception, state update, controller decision, action projection, and input stages
- action-engine permission, focus, rate, hold-duration, release, and backend-execution guardrails
- guarded live-action smoke through an injected backend only after dry-run latency evidence, explicit input policy allowance, and focus guard success
- optional slow-planner sidecar that publishes only validated hints without blocking reflex latency

This is still not the full off-the-shelf vision stack and must not be treated as completion. It can replay and trace compact local vision evidence, but it does not ship live local detector/OCR/segmentation/model adapters over captured pixels, continuous streaming capture, a default OS input backend, high-volume persisted replay traces, or target-specific visual calibration.

## Required Before This Plan Is Done

- Add a measured Weather lookup navigation adapter for the concrete command "show me the weather for SF".
- Prove fast local navigation from parsed intent, local app observation, deterministic controller state, and guarded live input, not remote planning.
- Add a default narrow macOS app-control backend for launch/focus/type/select/verify with focus guard and emergency release.
- Add result verification through Accessibility or screenshot/OCR fallback.
- Add continuous streaming capture once queue-depth, stale-result, and trace sinks are ready for longer sessions.
- Add durable high-volume replay trace persistence and target-specific benchmark baselines.
- Keep segmentation/OCR optional and introduce them only with cropped, measured, target-specific evidence.

## Where To Look

- Ultralytics supported models: https://docs.ultralytics.com/models/
- YOLO11 model card: https://huggingface.co/Ultralytics/YOLO11
- Segment Anything repository: https://github.com/facebookresearch/segment-anything
- SAM2 repository: https://github.com/facebookresearch/sam2
- FastSAM repository: https://github.com/CASIA-LMC-Lab/FastSAM
- ONNX Runtime execution providers: https://onnxruntime.ai/docs/execution-providers/
- ONNX Runtime TensorRT EP: https://onnxruntime.ai/docs/execution-providers/TensorRT-ExecutionProvider.html
- ONNX Runtime DirectML EP: https://onnxruntime.ai/docs/execution-providers/DirectML-ExecutionProvider.html
- Microsoft DXGI Desktop Duplication API: https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/desktop-dup-api
- Apple ScreenCaptureKit: https://developer.apple.com/documentation/screencapturekit
- Apple Core ML: https://developer.apple.com/machine-learning/core-ml/
- OpenAI model guide: https://developers.openai.com/api/docs/models
- OpenAI Responses API: https://platform.openai.com/docs/api-reference/responses
