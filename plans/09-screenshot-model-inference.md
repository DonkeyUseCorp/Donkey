# Screenshot Model Inference

## Goal

Capture screenshots or screen regions and feed them into a low-latency vision model that emits compact perception signals for the controller.

This is the visual fallback when DOM parsing, template matching, or simple CV are not enough.

## Core Rule

The reflex loop may use small local vision models. It must not depend on a large remote VLM.

Large VLMs can still be useful for slow planner snapshots, debugging, labeling, and recovery.

## Pipeline

```text
Screen Region
  -> Raw Pixel Buffer
  -> Crop / Resize / Normalize
  -> Low-Latency Vision Model
  -> Detections / Labels / Embeddings
  -> World State
  -> Fast Controller
```

Keep screenshots as raw pixel buffers for the hot path. Encoding to PNG or JPEG is usually a slow-path/debug operation.

## Model Jobs

Use a model only for perception questions that justify it:

- object detection
- player/enemy localization
- UI state classification
- minimap interpretation
- inventory/menu recognition
- OCR-like recognition when native OCR is too slow or brittle
- learned affordance detection, such as "clickable target" or "danger zone"

Avoid asking the model broad questions like "what should I do?" in the reflex loop. That belongs to the planner.

## Capture Strategy

Use the smallest input that preserves the needed signal:

1. capture the game window, not the whole desktop
2. crop to the gameplay area
3. crop to regions of interest when possible
4. downscale to the model's native input size
5. run high-resolution inference only on slow-path snapshots

For multi-region perception, prefer several small crops over one large full-frame model input if the total measured latency is lower.

## Runtime Choices

Pick the runtime based on measured latency in the target environment:

- platform-native acceleration when available
- ONNX Runtime for portable local inference
- TensorRT/Core ML/DirectML/OpenVINO where they reduce p95 latency
- WebGPU/WebNN for browser-contained demos when practical
- CPU inference only when the model is tiny and predictable

The plan should keep the model interface abstract so runtimes can be swapped after benchmarking.

## Hot-Path Rules

- Warm the model before live control starts.
- Reuse input/output buffers.
- Avoid cross-process image copies.
- Avoid image compression in the reflex loop.
- Use quantized or smaller models when accuracy allows.
- Drop stale frames instead of queuing inference.
- Emit confidence with every model result.
- Keep the controller dependent on structured outputs, not raw model tensors.

## Model Output Shape

Convert model outputs into world-state fields:

```text
timestamp
source_frame_id
model_id
input_region
input_size
detections
classifications
keypoints
confidence
inference_ms
preprocess_ms
```

Do not expose model-specific tensor formats to the controller.

## Measurement

Track every part of screenshot-to-model latency:

- capture_ms
- crop_ms
- resize_ms
- normalize_ms
- upload_ms, if GPU-backed
- inference_ms
- decode_ms
- world_state_update_ms
- model_result_age_ms

Report p50, p95, and p99 for each stage.

Also record:

- model name/version
- runtime/backend
- precision, such as fp32/fp16/int8
- input resolution
- batch size
- device used
- warm/cold run status

## Quality Measurement

Low latency only matters if the model output is useful.

Track:

- false positive rate
- false negative rate
- confidence calibration
- missed-action count
- wrong-action count
- recovery count after bad perception

For games, benchmark on recorded traces first, then live runs.

## Slow-Path VLM Use

Large VLMs can still help outside the reflex loop:

- identify what a new screen means
- label training data
- explain failure traces
- suggest new regions of interest
- recover when the fast model is confused

Slow-path outputs should become hints, labels, or updated configuration. They should not block immediate control.

## First Milestones

1. Build raw screenshot capture into a fixed-size tensor.
2. Measure crop, resize, normalize, and copy costs separately.
3. Add a tiny placeholder model or model stub with identical input/output shape.
4. Add one real low-latency model for the first visual task.
5. Emit model results into the common world-state schema.
6. Add latency and quality reports for recorded frames.
7. Run a live latest-frame-wins inference loop.

## Acceptance Criteria

- Screenshot-to-model p95 latency is under the perception budget for the first demo.
- No PNG/JPEG encode/decode occurs in the reflex loop.
- Model cold-start/warmup is measured separately from steady-state latency.
- The controller receives structured world-state updates, not raw screenshots or tensors.
- Stale inference results are detected and dropped.
