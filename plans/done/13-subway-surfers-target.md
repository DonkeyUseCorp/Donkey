# Subway Surfers Target Profile

> Archived status: historical context only. This file is not an active implementation queue. Supported behavior lives in `docs/`; future work from this idea needs a fresh active plan created deliberately.

## Goal

Use Subway Surfers as a high-pressure iPhone Mirroring target for low-latency screenshot perception and swipe control.

This is a strong production-readiness target, but not the first supported target. The game is fast, visual, and swipe-driven, so it should come after the agent can reliably capture, calibrate, and input into the iPhone Mirroring window.

## Why Subway Surfers

Subway Surfers is useful because:

- it is single-player endless running
- the character moves forward automatically
- the control set is small
- mistakes are visually obvious
- latency directly affects survival
- it runs on iPhone and can be accessed through iPhone Mirroring
- the score/distance gives a simple success metric

It is harder than tap-only games because the core inputs are swipes, timing, and fast lane decisions.

## Source

App Store: https://apps.apple.com/us/app/subway-surfers/id512939461

Current App Store notes:

- free with in-app purchases
- iPhone and iPad support
- action category
- Game Center support
- age rating 9+

Use a test device/account and avoid purchase flows.

## Input Model

Core controls:

- swipe left: move one lane left
- swipe right: move one lane right
- swipe up: jump
- swipe down: roll
- double tap: hoverboard, if enabled/available

Through iPhone Mirroring:

- Mac drag/swipe gestures need to map reliably to iPhone swipes
- click/tap may start runs or dismiss menus
- keyboard shortcuts are useful for iPhone navigation, not core gameplay
- a synthetic controller should emit calibrated tap/swipe commands for repeatability

First implementation should focus on:

- lane left
- lane right
- jump
- roll

Defer:

- hoverboard timing
- power-up strategy
- missions/events
- ads/rewards
- menus beyond starting/restarting

## Perception Model

Subway Surfers is mostly screenshot/model perception.

Useful signals:

- current lane of player
- nearest obstacle lane
- obstacle type: train, barrier, sign, low obstacle
- gap/open lane
- upcoming coin/power-up, optional
- game-over screen
- start/retry buttons
- score/distance text, optional

Likely perception approaches:

1. heuristic lane segmentation from the screen crop
2. template matching for common obstacles and menus
3. small vision model for obstacle/lane classification
4. OCR only for score/debug, not frame-critical control

DOM parsing does not apply.

## World State

Minimum state:

```text
timestamp
frame_id
player_lane
player_state
nearest_obstacles
safe_lanes
recommended_action
confidence
game_phase
```

`game_phase` values:

```text
menu
running
crashed
ad_or_offer
unknown
```

## Controller Policy

Start with a simple reflex policy:

1. detect immediate obstacle in current lane
2. choose left/right if adjacent lane is safe
3. jump or roll if the obstacle type requires vertical action
4. do nothing if current lane is safe
5. pause if confidence is low or screen is unknown

The controller should emit at most one swipe decision per short cooldown window so it does not overcorrect.

## Latency Target

For this target:

- Mac-side capture/perception/controller/input p95 under 100ms
- screenshot-model path p95 under 50ms if using a model
- swipe execution p95 under 10ms after action command
- mirroring/game visual response measured separately

Subway Surfers gets faster over time, so early success should be measured in survival duration and avoided obstacles, not infinite play.

## Measurement

Track:

- capture_ms
- preprocessing_ms
- inference_ms
- decision_ms
- input_ms
- visual_response_ms
- total_mac_side_ms
- stale_frame_rate
- wrong_swipe_rate
- missed_obstacle_rate
- survival_time
- score/distance, if readable

Add event labels:

- obstacle_seen
- action_chosen
- swipe_sent
- obstacle_cleared
- crash_detected
- retry_tapped

## Calibration

Before each run:

1. locate the iPhone Mirroring window
2. identify the iPhone content rectangle
3. detect portrait/landscape orientation
4. map the three gameplay lanes to screen coordinates
5. validate swipe gesture distance and duration
6. verify the game reacts to a safe menu tap/swipe

Swipe calibration should tune:

- start point
- end point
- duration
- minimum distance
- cooldown between swipes

## Safety

Use a test setup:

- dedicated test iPhone if available
- no payment method or purchase restrictions enabled
- avoid purchases, ads, rewards, and login flows
- stop on App Store/payment/login/system dialogs
- stop if iPhone Mirroring disconnects
- stop if window focus changes

Do not use leaderboard or social features as success criteria.

## First Milestones

1. Open Subway Surfers in iPhone Mirroring.
2. Capture the iPhone Mirroring content rectangle.
3. Start/restart a run with a tap.
4. Calibrate left/right/up/down swipes.
5. Detect `menu`, `running`, and `crashed` phases.
6. Segment screen into three lanes.
7. Detect obvious near-lane obstacles.
8. Execute a reflex dodge policy.
9. Record traces and measure survival duration.
10. Compare synthetic swipe latency and success rate across gesture durations.

## Acceptance Criteria

- The agent can start a run and detect when gameplay is active.
- The agent can perform reliable left/right/up/down swipes through iPhone Mirroring.
- The agent can survive longer than a no-op baseline.
- Crashes are traceable to perception, decision, input, or mirroring latency.
- No in-app purchases, ads, or external account flows are touched.
