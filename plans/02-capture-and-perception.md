# Capture And Perception

## Goal

Convert screen pixels into a compact world state quickly enough for real-time control.

The perception layer should answer only the questions the controller needs right now.

For browser games and web apps, DOM parsing can be an additional perception channel. Prefer direct DOM signals over pixel inference when they are available, stable, and fast enough. See [08-dom-parsing.md](08-dom-parsing.md).

For visual targets that cannot be parsed through the DOM, screenshots can feed a low-latency vision model. Keep that path local, cropped, and benchmarked. See [09-screenshot-model-inference.md](09-screenshot-model-inference.md).

## Capture Plan

Start with window or region capture, not whole-desktop capture.

Priority order:

1. Capture only the game window.
2. Crop to the gameplay area.
3. Crop further to regions of interest when possible.
4. Lower resolution for controller signals.
5. Keep occasional high-resolution snapshots for the slow planner.

## Perception Modes

Use the cheapest technique that works:

| Need | Preferred Method |
| --- | --- |
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
scene_id
player_position
player_velocity
targets
hazards
resources
active_menu
confidence
raw_signals
```

The controller should consume this state without needing raw pixels.

## Fast Path

Per frame:

1. Read latest captured frame.
2. Apply crop and downscale.
3. Run cheap detectors.
4. Update tracks from previous state.
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

1. Capture a selected window at stable frame rate.
2. Measure capture latency and copy cost.
3. Build a region cropper.
4. Add simple object detection for the first supported game.
5. Emit a world-state JSON event each frame.
6. Record traces for replay.
7. Benchmark screenshot-to-model inference on cropped regions.

## Acceptance Criteria

- Capture can run at 30 FPS minimum for the first supported target.
- Perception p95 stays under 50ms.
- The controller never reads raw screenshots directly.
- Full-resolution snapshots are outside the reflex loop.
- Model input dimensions and preprocessing cost are included in perception latency.
