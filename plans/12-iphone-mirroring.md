# iPhone Mirroring

## Goal

Use Apple's iPhone Mirroring app as the primary near-term target surface for mobile-game and mobile-app automation from the Mac.

This lets the agent interact with real iPhone apps through a Mac window, using the same desktop capture, perception, and input architecture.

## Feasibility

Yes, this is the main near-term use case.

The mirroring layer adds wireless latency and input translation that the agent does not control, so measurement must separate Mac-side latency from iPhone/mirroring response latency. That is a reason to instrument carefully, not a reason to defer the target.

## How It Fits The Architecture

```text
iPhone Game
  -> iPhone Mirroring App Window On Mac
  -> Mac Window Capture
  -> Screenshot / Model / OCR Perception
  -> World State
  -> Fast Controller
  -> Mac Mouse / Keyboard Input
  -> iPhone Mirroring
  -> iPhone Game
```

The agent should see iPhone Mirroring as another desktop window target.

PhoneAgent is a useful reference for a second iOS-control path: an XCTest-hosted JSON-RPC bridge that can return accessibility trees, screenshots, context, and perform actions like open app, tap, tap element, enter text, scroll, swipe, and stop. Treat it as a complementary iOS automation backend and prompt pattern, not a replacement for the iPhone Mirroring gameplay loop. See [17-ios-control-prompt.md](17-ios-control-prompt.md).

## Apple Requirements And Constraints

Current Apple requirements include:

- macOS Sequoia 15 or later
- Mac with Apple silicon or Apple T2 Security Chip
- iPhone with iOS 18 or later and a passcode
- same Apple Account with two-factor authentication
- Wi-Fi and Bluetooth enabled
- iPhone locked and near the Mac
- one Mac and one iPhone connected at a time

Important constraints:

- iPhone Mirroring is unavailable in the European Union.
- The Mac cannot be using AirPlay or Sidecar during iPhone Mirroring.
- iPhone camera and microphone are not available through iPhone Mirroring.
- Some protected media may not mirror correctly.
- A wireless game controller for iPhone apps should be connected to the iPhone, not the Mac.

## Good First iPhone Game Types

Prefer:

- tap-only games
- drag/simple-swipe games
- puzzle games
- card games
- turn-based games
- idle/clicker games
- single-player games with no anti-cheat
- games with stable portrait or landscape orientation

Avoid early:

- multiplayer games
- anti-cheat games
- rhythm games
- twitch shooters
- games requiring multi-touch
- games requiring accelerometer or gyro
- camera or microphone games
- games requiring complex controller input

## Perception Path

Assume screenshot/model perception first.

Possible inputs:

- Mac window screenshot of iPhone Mirroring
- cropped game viewport
- OCR for labels, scores, and menus
- small vision model for buttons, objects, or game state
- template matching for stable UI elements

DOM parsing generally does not apply unless the iPhone app is a web app exposed through a controllable browser context.

## Input Path

Use Mac input against the iPhone Mirroring window:

- click maps to tap
- click-and-hold maps to touch-and-hold
- scroll/trackpad gestures can map to swipe
- keyboard can type into iPhone text fields
- Mac shortcuts can navigate Home Screen, App Switcher, and Spotlight

Assume single-pointer input until tested. Multi-touch gestures should not be part of the first target profile.

Use a synthetic controller adapter for repeatable taps and swipes. The controller should generate calibrated mouse down, movement, and mouse up events inside the iPhone Mirroring content rectangle instead of relying on hand gestures. See [14-synthetic-controller.md](14-synthetic-controller.md).

For controller games:

- pair the game controller directly to the iPhone
- treat controller automation as a separate backend
- do not assume Mac keyboard/mouse can emulate all controller interactions through mirroring

## Latency Risks

- wireless mirroring delay
- variable Wi-Fi/Bluetooth conditions
- Mac window capture overhead
- iPhone Mirroring rendering/composition overhead
- Mac input event translation
- game response latency on the iPhone
- orientation changes resizing the capture region
- app animations hiding true state

The measured reflex loop should distinguish:

- Mac capture latency
- perception/model latency
- Mac input execution latency
- mirroring/game response latency
- visual confirmation latency

## Measurement Plan

Start with a simple instrumentable iPhone target if possible, such as a local web app opened on iPhone Safari.

Measure:

- time from visual stimulus in the mirrored window to agent action
- time from Mac input event to visible iPhone response
- p50/p95/p99 response latency across a 5-10 minute run
- dropped or stale screenshot frames
- wrong tap rate
- coordinate drift after orientation/window-size changes

If using an App Store game, use external observation or visual confirmation because the app will not expose internal timestamps.

## Calibration

The coordinate mapping must handle:

- iPhone Mirroring window position
- iPhone screen content bounds inside the window
- portrait vs landscape orientation
- Mac display scaling
- window resizing
- letterboxing or toolbar offsets

Add a calibration check before each run:

1. locate the iPhone Mirroring window
2. identify the visible iPhone content rectangle
3. click known safe points
4. verify visual response
5. lock the capture region for the run

## Safety

Add mobile-specific safety rules:

- use only offline or single-player games
- avoid accounts with purchases or sensitive data
- disable in-app purchase flows for test devices when possible
- stop if the mirrored window loses focus
- stop if the app opens payment, login, contacts, messages, or system settings
- release/stop input on disconnect

Use a dedicated test iPhone or test Apple Account if this becomes a serious target.

## First Milestones

1. Open iPhone Mirroring and capture its window.
2. Build coordinate calibration for portrait and landscape.
3. Click/tap a known safe UI element reliably.
4. Measure Mac input to visible response latency.
5. Run a tap-only game or local iPhone Safari test page.
6. Add screenshot-model or template perception on the mirrored window.
7. Record and replay mirrored-window traces.

## Acceptance Criteria

- The agent can identify and capture the iPhone Mirroring content region.
- Tap coordinates are accurate after window movement and resizing.
- p95 Mac-side capture/perception/action latency remains under the desktop budget.
- Additional mirroring/game response latency is measured separately.
- The target game is offline/single-player and has no anti-cheat risk.
