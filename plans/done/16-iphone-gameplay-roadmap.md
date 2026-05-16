# iPhone Gameplay Roadmap

> Archived status: historical context only. This file is not an active implementation queue. Supported behavior lives in `docs/`; future work from this idea needs a fresh active plan created deliberately.

## Goal

Make the agent good at playing iPhone games through Apple's iPhone Mirroring app.

This is the near-term product focus. Other targets are useful only when they help this path.

## Product Thesis

iPhone Mirroring turns mobile apps into a Mac window. If the agent can capture that window, understand game state, and send calibrated taps/swipes/controllers with low latency, it can play a broad class of iPhone games without custom game integrations.

## Core Capabilities

Build these in order:

1. iPhone Mirroring window detection
2. iPhone content-rectangle calibration
3. synthetic tap/swipe controller
4. screenshot capture of the mirrored content
5. low-latency perception from screenshots
6. game phase detection: menu, running, crashed, ad/offer, unknown
7. safety guard for purchases, login, ads, system dialogs
8. trace recording and replay
9. per-game adapters
10. model-assisted perception when heuristics are not enough
11. optional PhoneAgent-style RPC/accessibility backend for app navigation, setup, and non-frame-critical iOS control

## Game Progression

### Stage 1: Harness

Target:

- local iPhone Safari test page
- simple tap/swipe detector

Purpose:

- measure mirroring latency
- calibrate coordinates
- verify tap/swipe synthesis
- test focus and stop behavior

Exit criteria:

- 99% tap recognition on a static target
- 95% swipe recognition in four directions
- p95 Mac-side action latency under 100ms
- no stuck input after 10-minute soak

### Stage 2: Simple iPhone Games

Target:

- tap-only games
- puzzle/card/turn-based games
- simple one-finger swipe games

Purpose:

- prove real App Store gameplay
- build menu/retry handling
- harden screenshot perception
- collect traces

Exit criteria:

- agent can play for 3-5 minutes
- failures are classified by perception, control, latency, or safety guard
- no purchase/ad/account flows are touched

### Stage 3: Subway Surfers

Target:

- Subway Surfers through iPhone Mirroring

Purpose:

- flagship latency and perception target
- lane tracking
- obstacle detection
- left/right/up/down swipe control

Exit criteria:

- agent survives longer than no-op and random baselines
- wrong-swipe and missed-obstacle rates are measured
- crashes are explainable from traces
- gameplay improves across recorded runs

### Stage 4: Controller-Supported iPhone Games

Target:

- iPhone games with controller support

Purpose:

- validate generic controller abstraction
- reduce coordinate-dependence
- broaden game coverage

Exit criteria:

- controller backend can drive at least one iPhone controller game
- backend limitations through iPhone Mirroring are documented
- touch and controller mappings share the same semantic action layer

## Success Metrics

Measure both latency and game competence:

- p50/p95/p99 Mac-side loop latency
- iPhone mirroring visual-response latency
- tap/swipe recognition rate
- stale-frame rate
- wrong-action rate
- missed-action rate
- survival time
- score/distance when readable
- retries completed
- safety stops

## Safety Rules

- Use offline or single-player games first.
- Avoid anti-cheat and multiplayer.
- Use a test iPhone/account where possible.
- Stop on purchases, App Store prompts, login, messages, contacts, system settings, ads, or unknown screens.
- Keep all remote model calls outside the reflex loop.
- Record only the cropped mirrored game content when possible.

## Immediate Build Order

1. Finish the macOS synthetic controller foundation.
2. Add iPhone Mirroring window/content detection.
3. Add a calibration command for tap and four swipe directions.
4. Add screenshot capture of the calibrated content rectangle.
5. Add trace logging for every capture, perception result, and input command.
6. Build the local iPhone Safari harness.
7. Capture a PhoneAgent-inspired iOS control prompt and backend contract.
8. Move to one simple iPhone game.
9. Move to Subway Surfers.
