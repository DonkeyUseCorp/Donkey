# Action Engine

> Active status: not complete. Current action-engine support provides guardrails, traces, and injected-backend smoke execution, but not the narrow default macOS app-control backend needed for the first fast-navigation benchmark.

## Goal

Execute app activation, keyboard, mouse, Accessibility, and controller actions with low latency and predictable timing.

## Responsibilities

- app launch and activation
- keyboard press/release
- text entry
- mouse movement
- mouse click/drag
- Accessibility focus/action when trusted
- controller input, if needed
- action scheduling
- input cancellation
- focus checks

## Design

The controller emits action commands:

```text
press_key(W, duration=40ms)
type_text("San Francisco")
move_mouse(dx=10, dy=-4)
click(button=left)
tap(x, y)
swipe(start_x, start_y, end_x, end_y, duration=80ms)
press_button(A, duration=40ms)
set_axis(left_stick_x, 0.5)
release_all()
launch_app(bundle_id=com.apple.weather)
activate_app(bundle_id=com.apple.weather)
perform_accessibility_action(element_id=search-field, action=focus)
```

The action engine translates commands into OS input calls.

For local app tasks, prefer the safest high-level primitive that works:

1. Launch or activate the target app through the app-control backend.
2. Use Accessibility focus/actions when trusted and the target element is confidently identified.
3. Use guarded keyboard text entry for ordinary search text.
4. Use mouse clicks only when coordinates are derived from typed state and focus guard passes.

For touch-style targets such as iPhone Mirroring, the action engine should expose a synthetic controller adapter. It turns semantic commands like `swipe_left` or `tap_lane_center` into calibrated mouse/touch-like gestures. See [14-synthetic-controller.md](14-synthetic-controller.md).

For games that support controllers, the action engine should expose a generic gamepad abstraction with buttons, sticks, triggers, and directional pads. See [15-gamepad-controller.md](15-gamepad-controller.md).

## Rules

- Input execution should be fire-and-forget where safe.
- Long key holds must have explicit release times.
- The engine should release all inputs on shutdown or loss of focus.
- The controller should not call OS input APIs directly.
- Every command should be timestamped and traceable.
- App launch/focus commands must be traceable and covered by tool policy.
- Text entry must be scoped to the verified focused app/control.
- Accessibility actions must not run on sensitive or review-required surfaces.

## Mouse Strategy

For games, mouse movement should support:

- relative movement
- absolute movement
- smooth movement over a short duration
- instant click after movement
- calibrated sensitivity per game

## Keyboard Strategy

Support:

- tap
- hold
- chord
- release
- type text
- rate limit

Movement keys should be represented as desired direction first, then converted to key states. This prevents conflicting commands like left and right being held accidentally.

For the Weather demo, text entry should be a first-class command so traces can show the normalized entity being typed without exposing unrelated keyboard events.

## App-Control Strategy

Support a narrow macOS backend for the first target:

- launch app by bundle identifier
- activate/focus app
- verify frontmost app before input
- focus a known Accessibility element when available
- fall back to keyboard shortcut/search only when focus is safe

This backend is intentionally narrower than a general desktop-control agent. Add capabilities only when a task adapter needs them and the guardrails can explain them.

## Latency Risks

- OS accessibility/input permission prompts.
- APIs that add smoothing or delay.
- Cross-process command queues.
- Too many tiny scheduled timers.
- Failure to release inputs after an exception.

## First Milestones

1. Add semantic app-control commands for launch, activate, type text, focus element, click/select, and verify.
2. Implement a narrow macOS backend for Weather behind existing guardrails.
3. Add input and app-control tracing.
4. Add focus guard for target app and target control.
5. Add emergency release.
6. Measure command-to-input latency for Weather lookup.
7. Calibrate mouse movement only if Accessibility/keyboard control is insufficient.

## Acceptance Criteria

- Input execution p95 is under 5ms after command creation.
- App launch/focus and text-entry latency are measured separately.
- All held inputs release on stop.
- Commands can be replayed from a trace.
- Weather lookup live input cannot run unless the Weather app/control is verified safe.
