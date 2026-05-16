# Capture And Perception

> Active status: not complete. Current capture/perception support includes target-window frames and metadata perception, but not the live observation needed to verify the first fast-navigation benchmark.

## Goal

Convert app, window, Accessibility, and screen observations into compact state quickly enough for local task control.

The perception layer should answer only the questions the controller needs right now.

For the first Weather task, the controller needs app/task facts more than pixels: whether Weather is running and frontmost, whether the search field or search results are available, what location is visible, and whether the requested city is verified.

For Mac apps, Accessibility is the preferred observation channel when trusted and available. Prefer direct app/UI structure over pixel inference when it is available, stable, and fast enough.

For browser games and web apps, DOM parsing can be an additional perception channel. Prefer direct DOM signals over pixel inference when they are available, stable, and fast enough. See [08-dom-parsing.md](08-dom-parsing.md).

For visual targets that cannot be parsed through the DOM, screenshots can feed a low-latency vision model. Keep that path local, cropped, and benchmarked. See [09-screenshot-model-inference.md](09-screenshot-model-inference.md).

## Capture Plan

Start with app/window metadata and Accessibility snapshots. Use window or region capture only when structured app observation is insufficient.

Priority order:

1. Resolve the target app/window.
2. Read Accessibility state for controls and labels.
3. Capture only the target window when Accessibility cannot answer the question.
4. Crop to the relevant app region or control.
5. Lower resolution for controller signals.
6. Keep occasional high-resolution snapshots for the slow planner.

## Perception Modes

Use the cheapest technique that works:

| Need | Preferred Method |
| --- | --- |
| Mac app focus/running state | window metadata, NSWorkspace/Accessibility |
| Mac app controls and labels | Accessibility snapshot/action metadata |
| Weather visible location | Accessibility label/value first, cropped OCR fallback |
| browser UI/web app state | live DOM query, DOM snapshot, or parsed HTML |
| UI/menu state | template matching, OCR only where needed |
| visually complex state | cropped screenshot into a small vision model |
| player/enemy location | color thresholding, sprite matching, tiny detector |
| aim target | local object detector, contour tracking |
| motion | frame differencing, optical flow, tracked boxes |
| health/resources | fixed-region OCR or bar measurement |
| confusion recovery | slow planner snapshot |

## World State

Keep world state small and typed:

```text
timestamp
intent_id
scene_id
app_id
task_type
visible_location
search_field_state
result_state
confidence
raw_signals
```

The controller should consume this state without needing raw pixels.

## Fast Path

Per frame:

1. Read latest app/window/Accessibility state.
2. Capture and crop only if structured state is missing.
3. Run cheap OCR/template fallback only on the crop.
4. Update task state from previous state.
5. Emit latest world state.

When using a model, the fast path should pass preprocessed tensors or raw pixel buffers directly to inference. Avoid PNG/JPEG encoding in the reflex loop.

## Slow Path

Occasionally:

1. Save high-resolution snapshot.
2. Ask planner to classify scene, objective, or recovery action.
3. Update controller policy or goal.

Slow-path output must be advisory. The agent should keep acting while waiting.

For web targets, slow-path snapshots may include compact DOM summaries alongside screenshots. Do not send a full DOM tree to the planner unless the page is small or the summary failed.

## First Milestones

1. Resolve and observe the Weather app window.
2. Measure app/window/Accessibility observation latency.
3. Extract search/result/location state for Weather.
4. Build a region cropper for Weather screenshot fallback.
5. Add cropped OCR fallback only if Accessibility cannot verify location.
6. Emit a world-state JSON event for each task step.
7. Record traces for replay.
8. Benchmark screenshot-to-model inference on cropped regions as a later visual-target path.

## Acceptance Criteria

- App observation p95 stays under the target budget for Weather lookup.
- Capture can run at 30 FPS minimum for later visual targets.
- Perception p95 stays under 50ms when screenshot/OCR fallback is used.
- The controller never reads raw screenshots directly.
- Full-resolution snapshots are outside the reflex loop.
- Model input dimensions and preprocessing cost are included in perception latency.
- Weather result verification is traceable to Accessibility or cropped OCR evidence.
