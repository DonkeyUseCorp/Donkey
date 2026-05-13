# Synthetic Controller

## Goal

Build a generic synthetic input controller that emits calibrated input into a target game or app.

This layer should work across games by separating:

- semantic game actions
- normalized controller actions
- target-specific mappings
- OS or device-specific input backends

Touch gestures for iPhone Mirroring are one backend. A virtual gamepad is another backend. Keyboard/mouse is another.

## Core Idea

The fast controller should not know about screen coordinates, key codes, HID details, or OS input APIs.

It should emit semantic actions:

```text
move_left
move_right
jump
roll
attack
interact
pause
release_all
```

The synthetic controller maps those actions through a target profile:

```text
move_left -> gamepad.dpad_left
move_right -> gamepad.left_stick_x = 1.0
jump -> gamepad.button_south
roll -> touch.swipe_down
interact -> keyboard.E
```

## Architecture

```text
Fast Controller
  -> Semantic Action
  -> Action Mapper
  -> Normalized Input Command
  -> Backend Adapter
  -> Game / App
```

Backends can include:

- macOS Accessibility tree/action backend
- gamepad / controller
- touch gestures
- keyboard
- mouse
- browser automation
- emulator API

## Normalized Command Interface

Generic commands:

```text
press(action, duration_ms)
hold(action)
release(action)
set_axis(axis, value)
tap(point, duration_ms)
swipe(direction, distance_px, duration_ms)
drag(start, end, duration_ms)
release_all()
stop()
```

Gamepad-shaped commands:

```text
press_button(button, duration_ms)
hold_button(button)
release_button(button)
set_left_stick(x, y)
set_right_stick(x, y)
set_left_trigger(value)
set_right_trigger(value)
tap_dpad(direction, duration_ms)
release_gamepad()
```

Touch-shaped commands:

```text
tap(point, duration_ms=30)
double_tap(point, gap_ms=80)
swipe(direction, distance_px, duration_ms)
drag(start, end, duration_ms)
```

## Target Mappings

Each game should define a mapping file:

```text
target_id
backend
semantic_actions
bindings
timing
dead_zones
cooldowns
safety_rules
```

Example:

```text
target_id: subway-surfers-iphone-mirroring
backend: touch
move_left: swipe_left
move_right: swipe_right
jump: swipe_up
roll: swipe_down
hoverboard: double_tap_center
```

Example:

```text
target_id: generic-controller-game
backend: gamepad
move_left: left_stick_x=-1.0
move_right: left_stick_x=1.0
jump: button_south
attack: button_west
pause: button_menu
```

## Backend Selection

Pick the backend per target:

| Target Type | Preferred Backend |
| --- | --- |
| native Mac app with accessible controls | macOS Accessibility backend |
| native PC/Mac game with controller support | gamepad backend |
| emulator with API | emulator backend |
| iPhone Mirroring touch game | touch gesture backend |
| browser canvas game | mouse/keyboard or browser backend |
| DOM game/app | browser automation or DOM action backend |

If a game supports controllers, prefer the gamepad backend because it is usually more stable than screen-coordinate mouse gestures.

## Calibration State

Store calibration separately from controller logic:

```text
target_id
target_window_id
target_window_title
backend
content_rect
display_scale
device_orientation
gamepad_layout
axis_dead_zones
button_hold_ms
gesture_distance_px
gesture_duration_ms
cooldowns
last_verified_at
```

## Timing Rules

- Use monotonic timestamps for every command.
- Do not queue stale commands.
- Enforce per-command deadlines.
- Prevent contradictory held inputs.
- Release held axes/buttons on stop.
- Rate-limit repeated taps, swipes, and button presses.
- Keep backend calls out of the perception loop.

Trace every command:

```text
action_id
semantic_action
normalized_command
backend
target_id
created_at
input_start_at
input_end_at
visual_confirmation_at
success
```

## Safety Rules

- Verify the target before input.
- Stop if the target window or device disappears.
- Stop if confidence is low.
- Stop on payment, login, system dialog, or unknown screen.
- Always support `stop()` and `release_all()`.
- Release all held buttons, keys, sticks, triggers, and mouse buttons on shutdown.

## Acceptance Criteria

- The fast controller emits semantic actions, not backend-specific input.
- A target mapping can swap touch, keyboard/mouse, and gamepad backends without changing controller logic.
- Held inputs are always released on stop.
- Commands are timestamped and replayable.
- Backend latency is measured separately from decision latency.
