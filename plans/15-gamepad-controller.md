# Gamepad Controller

## Goal

Build a generic controller/gamepad abstraction that can drive any supported game with controller input, without hardcoding a single game.

The agent should think in semantic actions. The gamepad layer should translate those actions into normalized buttons, sticks, triggers, and D-pad commands.

## Why This Matters

Many games expose cleaner input through controller support than through mouse/keyboard or touch gestures.

Benefits:

- fewer coordinate calibration problems
- lower ambiguity than mouse gestures
- stable action space
- easier replay
- easier game-to-game remapping
- useful for emulators, desktop games, and controller-friendly mobile games

## Generic Gamepad Model

Use a common modern controller shape:

```text
buttons:
  south
  east
  west
  north
  left_bumper
  right_bumper
  left_stick_button
  right_stick_button
  menu
  view
  home

dpad:
  up
  down
  left
  right

axes:
  left_stick_x  [-1.0, 1.0]
  left_stick_y  [-1.0, 1.0]
  right_stick_x [-1.0, 1.0]
  right_stick_y [-1.0, 1.0]
  left_trigger  [0.0, 1.0]
  right_trigger [0.0, 1.0]
```

Avoid naming the base abstraction after one vendor layout. Put Xbox/PlayStation/Nintendo labels in mapping metadata.

## Command Interface

```text
press_button(button, duration_ms=40)
hold_button(button)
release_button(button)
tap_dpad(direction, duration_ms=40)
hold_dpad(direction)
release_dpad(direction)
set_left_stick(x, y)
set_right_stick(x, y)
set_left_trigger(value)
set_right_trigger(value)
neutralize_sticks()
release_all()
```

For low latency, axis updates should be cheap and not allocate.

## Game Mappings

Each game gets a mapping:

```text
target_id
backend
layout
semantic_action -> gamepad command
cooldowns
hold_durations
axis_curves
dead_zones
```

Example:

```text
jump -> press_button(south, 50ms)
dodge -> press_button(east, 50ms)
move_left -> set_left_stick(-1.0, 0.0)
move_right -> set_left_stick(1.0, 0.0)
aim_at -> set_right_stick(x, y)
shoot -> set_right_trigger(1.0)
stop_shoot -> set_right_trigger(0.0)
```

## Backend Options

Possible backends:

- virtual gamepad device
- hardware controller bridge
- emulator controller API
- browser Gamepad API test harness
- platform-specific HID driver

Backend choice depends on platform and target.

Important iPhone Mirroring caveat:

- Apple documents that wireless game controllers for iPhone apps should be connected to the iPhone, not the Mac.
- A Mac-side virtual controller may not control iPhone games through iPhone Mirroring.
- For iPhone games, gamepad automation may require a controller bridge paired directly to the iPhone, or the touch backend if controller bridging is not available.

## Backend Contract

Every backend should implement:

```text
connect()
is_available()
get_capabilities()
send(command)
release_all()
measure_latency()
disconnect()
```

Capabilities should declare:

```text
supports_buttons
supports_dpad
supports_analog_sticks
supports_triggers
supports_rumble
supports_low_latency
requires_focus
requires_pairing
```

## Safety

- Always release sticks to neutral on stop.
- Always set triggers to zero on stop.
- Avoid holding movement indefinitely without a deadline.
- Stop if backend disconnects.
- Stop if target loses focus when focus is required.
- Block inputs on payment/login/system screens.

## Measurement

Track:

- command_create_ms
- backend_send_ms
- device_update_ms, if measurable
- visual_response_ms
- dropped_command_count
- stale_command_count
- held_input_duration
- release_all_latency_ms

For controller games, visual response is the real proof that the backend works.

## Testing Plan

1. Build a local gamepad visualizer target.
2. Send every button and axis command.
3. Verify neutral/release behavior.
4. Measure p50/p95 command send latency.
5. Test one emulator or simple controller-friendly game.
6. Add a target mapping.
7. Replay a recorded action trace.

## Acceptance Criteria

- The same semantic controller can drive at least two different controller-supported targets by changing only the mapping/backend.
- Buttons, D-pad, sticks, and triggers are all supported in the normalized interface.
- `release_all()` reliably neutralizes every held input.
- Backend latency and visual response latency are measured.
- iPhone controller support is treated as a separate backend problem, not assumed through Mac iPhone Mirroring.

