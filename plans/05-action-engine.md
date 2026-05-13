# Action Engine

## Goal

Execute keyboard, mouse, and controller actions with low latency and predictable timing.

## Responsibilities

- keyboard press/release
- mouse movement
- mouse click/drag
- controller input, if needed
- action scheduling
- input cancellation
- focus checks

## Design

The controller emits action commands:

```text
press_key(W, duration=40ms)
move_mouse(dx=10, dy=-4)
click(button=left)
tap(x, y)
swipe(start_x, start_y, end_x, end_y, duration=80ms)
press_button(A, duration=40ms)
set_axis(left_stick_x, 0.5)
release_all()
```

The action engine translates commands into OS input calls.

For touch-style targets such as iPhone Mirroring, the action engine should expose a synthetic controller adapter. It turns semantic commands like `swipe_left` or `tap_lane_center` into calibrated mouse/touch-like gestures. See [14-synthetic-controller.md](14-synthetic-controller.md).

For games that support controllers, the action engine should expose a generic gamepad abstraction with buttons, sticks, triggers, and directional pads. See [15-gamepad-controller.md](15-gamepad-controller.md).

## Rules

- Input execution should be fire-and-forget where safe.
- Long key holds must have explicit release times.
- The engine should release all inputs on shutdown or loss of focus.
- The controller should not call OS input APIs directly.
- Every command should be timestamped and traceable.

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
- rate limit

Movement keys should be represented as desired direction first, then converted to key states. This prevents conflicting commands like left and right being held accidentally.

## Latency Risks

- OS accessibility/input permission prompts.
- APIs that add smoothing or delay.
- Cross-process command queues.
- Too many tiny scheduled timers.
- Failure to release inputs after an exception.

## First Milestones

1. Choose the input backend per OS.
2. Build a command interface.
3. Add input tracing.
4. Add focus guard.
5. Add emergency release.
6. Calibrate mouse movement for first demo.

## Acceptance Criteria

- Input execution p95 is under 5ms after command creation.
- All held inputs release on stop.
- Commands can be replayed from a trace.
