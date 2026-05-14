# Off-The-Shelf Run Loop

## Goal

Build the first real-time game assistant from existing components instead of custom model work.

Use LLMs, open-vocabulary detectors, Segment Anything-style models, OCR, templates, classical CV, and deterministic controllers. The system should be useful before any custom model work exists.

## Target Shape

```text
Screen Capture
  -> Crop / Normalize
  -> Off-The-Shelf Vision
  -> Game State
  -> Deterministic Controller
  -> Action Engine
  -> Mouse / Keyboard / Controller

Reasoning LLM
  <-> Goals / Hints / UI Understanding / Memory / Recovery
```

The hot loop is still local and bounded. The LLM can reason beside it, but action timing comes from deterministic logic over structured state.

## Core Rule

Do not build a custom model pipeline for the first version.

The first version should prove:

- capture is reliable
- perception can extract useful state from off-the-shelf models
- state is compact and timestamped
- controller rules can act on that state
- latency is measured end to end
- the LLM can help with strategy and recovery without blocking the loop

## Hot-Path Components

Use existing, swappable components:

- YOLO-family detector for boxes, UI elements, enemies, objects, and markers
- SAM / SAM2 / MobileSAM / FastSAM for masks when boxes are not enough
- OCR for text, scores, labels, and menus
- template matching for stable UI buttons and icons
- color/edge/motion heuristics for simple fast signals
- deterministic state machines for action decisions
- LLM planner only for slow hints and recovery

Avoid:

- custom policy models
- custom action models
- custom neural networks
- full LLM decision-making every frame
- Ollama or any chat LLM in the per-frame action path
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

Best default for iPhone Mirroring and Mac app control:

```text
ScreenCaptureKit
  -> IOSurface / CVPixelBuffer
  -> Core ML / Metal / ONNX Runtime CoreML EP
  -> synthetic input with Accessibility focus guard
```

Use Accessibility for window bounds, focus checks, dialogs, and setup flows. Use screenshot perception for the mirrored game content.

## Vision Options

### Detector First

Start with a detector when the game state can be represented as objects.

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

## Game State

Convert all perception outputs into a compact state object:

```text
state_id
frame_id
timestamp
target_id
scene_type
objects
masks
text
ui_flags
player_state
hazards
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

## Controller

Use deterministic logic over game state:

```text
Game State
  -> Policy Selector
  -> Rule / State Machine
  -> Semantic Action
  -> Calibrated Input
```

Examples:

- obstacle on left lane -> move center/right
- button visible and safe -> tap button center
- health low -> request planner recovery hint
- menu state unknown -> pause and ask LLM to classify snapshot
- target box center offset -> move/click toward center
- countdown text appears -> wait or prepare action

The controller should be boring, inspectable, and traceable.

## LLM Role

Use LLMs for:

- interpreting unfamiliar screens
- choosing objectives
- explaining failures
- deciding which detector/OCR/template signals matter
- suggesting recovery steps
- summarizing memory
- reading slow-path screenshots or UI snapshots
- producing structured planner hints

Do not use LLMs for:

- aiming every frame
- dodge timing
- tap/swipe timing
- continuous movement
- direct OS input

LLM output must become validated hints, not direct actions.

## First Demo Recommendation

Pick one game and one task.

Good first tasks:

- dodge obstacles from detected lanes/hazards
- tap a button when a visual condition appears
- navigate a repeated menu
- collect visible items
- use OCR to react to a countdown or label

Suggested first stack:

```text
Capture: ScreenCaptureKit for iPhone Mirroring, DXGI for Windows
Detector: YOLO-family nano/small model
Segmentation: MobileSAM or FastSAM as optional fallback
OCR: cropped-region OCR
Rules: deterministic state machine
Inference: ONNX Runtime, TensorRT, Core ML, or DirectML depending on platform
Reasoning: OpenAI Responses API or local Qwen/Phi/Gemma in a separate slow path
IPC: latest-frame-wins shared buffer
Runtime: native core where the hot path needs it
```

## Rollout

1. Choose one target and one behavior.
2. Define the state fields needed for that behavior.
3. Capture the target window and crop to the gameplay/content area.
4. Add one off-the-shelf detector or template signal.
5. Add one deterministic rule that emits a safe semantic action.
6. Add action calibration and focus guard.
7. Add trace logging and latency report.
8. Add optional segmentation only if detection/templates fail.
9. Add OCR only for text-dependent screens.
10. Add slow LLM recovery after the reflex loop works.

## Acceptance Criteria

- No custom model work is required.
- The hot loop can run with the LLM disabled.
- Every perception component is swappable.
- Every action is explainable from state, rule, and trace id.
- p95 reflex latency stays under the target budget.
- LLM output is validated before it changes controller configuration.
- Segmentation and OCR are cropped and measured before live use.

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
