# iOS Control Prompt

> Archived status: historical context only. This file is not an active implementation queue. Supported behavior lives in `docs/`; future work from this idea needs a fresh active plan created deliberately.

## Goal

Capture the operating prompt for controlling iOS, using PhoneAgent as a reference while keeping iPhone Mirroring gameplay as the main product path.

Reference:

- https://github.com/rounak/PhoneAgent

PhoneAgent is an experimental mobile automation project with two relevant ideas:

- an in-app iPhone agent using SwiftUI, XCTest, and the OpenAI Responses API
- an external JSON-RPC bridge that lets agents control iOS/Android devices

For this project, the most useful pattern is the structured control loop: inspect context, choose one action, execute, verify, repeat.

The same pattern applies on macOS through Apple's Accessibility APIs. macOS can expose an accessibility tree and actions for native controls, windows, menus, dialogs, and many app UIs. See [18-macos-accessibility.md](18-macos-accessibility.md).

## Backend Positioning

Use two iOS-control backends:

| Backend | Best Use | Tradeoff |
| --- | --- | --- |
| iPhone Mirroring window backend | real-time visual gameplay, Subway Surfers, App Store games | needs screenshot perception and calibrated Mac input |
| PhoneAgent-style RPC backend | app navigation, accessibility tree, screenshots, setup flows, non-frame-critical iOS actions | XCTest/RPC setup, not necessarily suitable for fast frame-by-frame gameplay |

The gameplay reflex loop should remain iPhone Mirroring first. The RPC backend can help with setup, menus, app launching, screenshots, and accessibility-grounded verification.

## PhoneAgent-Inspired Action Surface

Model the generic iOS action surface around:

```text
get_tree
get_screen_image
get_context
open_app
tap
tap_element
enter_text
scroll
swipe
stop
```

PhoneAgent's README describes these as shared RPC methods for iOS and Android, with an iOS-only `submit_prompt` for its in-app agent loop.

## Core iOS Control Loop

Use this prompt pattern for non-frame-critical iOS control:

```text
You are controlling an iOS device.

Loop:
1. Get context: accessibility tree plus screenshot when available.
2. Decide the next single safe action.
3. Prefer accessibility-tree targets when the UI is structured.
4. Use coordinate/touch actions only when necessary.
5. Execute one action.
6. Verify the result with a fresh tree, screenshot, or context.
7. Stop or ask for help on payment, login, system, privacy, unknown, or unsafe screens.

Rules:
- Use one action at a time.
- Do not queue actions against stale UI.
- Re-read the tree after animations, navigation, or failed taps.
- Prefer tap_element over raw tap when a reliable element frame exists.
- Prefer get_context when both tree and screenshot are useful.
- For games, use screenshot perception and the fast controller instead of slow tree reasoning.
- Keep remote model calls outside the reflex loop.
```

## Game-Specific Prompt Boundary

For iPhone games:

- use the prompt loop for menus, setup, app launch, and recovery
- use the fast screenshot/controller loop for live gameplay
- do not ask the slow planner to decide every dodge, tap, or swipe
- use `game_phase` to decide whether the slow iOS prompt loop is allowed

Recommended boundary:

```text
menu / setup / crashed / unknown -> iOS control prompt may act
running / live gameplay -> fast controller acts
payment / login / system / ad_or_offer -> stop or require explicit approval
```

## World-State Additions

Add optional iOS-control fields:

```text
ios_backend
bundle_identifier
accessibility_tree_id
screenshot_id
focused_app
game_phase
unsafe_screen_reason
last_verified_action_id
```

## Backend Contract

Whether the implementation is PhoneAgent, iPhone Mirroring, or a future bridge, expose a common interface:

```text
get_context() -> tree?, screenshot?, metadata
open_app(bundle_identifier)
tap(x, y)
tap_element(frame_or_element_id)
enter_text(target, text)
scroll(x, y, dx, dy)
swipe(x, y, direction)
stop()
```

Every response should include enough fresh context to verify progress when practical.

## Safety Rules

- Keep iOS control localhost/local-device oriented.
- Do not enter passwords, 2FA codes, payment details, or private messages automatically.
- Stop on App Store purchases, login screens, permission prompts, messages, contacts, system settings, or unknown sensitive screens.
- Use test devices/accounts where possible.
- Screenshot artifacts can contain sensitive phone data; crop to game content and redact when possible.

## When To Use PhoneAgent Ideas

Use them for:

- opening apps by bundle identifier
- reading accessibility trees
- tapping known UI elements
- entering text into structured fields
- taking screenshots for verification
- recovering from menus or settings screens

Avoid them for:

- per-frame Subway Surfers decisions
- low-latency dodge/jump/roll loops
- any gameplay path where RPC round trips make state stale

## First Milestones

1. Keep iPhone Mirroring as the primary gameplay backend.
2. Define the shared iOS control interface above.
3. Add an optional PhoneAgent-style backend adapter plan.
4. Build prompts that separate slow iOS UI control from fast gameplay control.
5. Use accessibility/context only when it improves reliability without hurting reflex latency.
