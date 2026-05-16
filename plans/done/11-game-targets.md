# Game Targets

> Archived status: historical context only. This file is not an active implementation queue. Supported behavior lives in `docs/`; future work from this idea needs a fresh active plan created deliberately.

## Goal

Choose iPhone games that expose latency problems quickly, avoid anti-cheat risk, and let the agent become good at mobile gameplay through iPhone Mirroring.

The project should not start with the most impressive iPhone game. It should start with the game that makes the iPhone Mirroring loop measurable.

## Selection Criteria

Prefer games with:

- offline or single-player play
- no anti-cheat
- simple action space
- fast visual feedback
- repeatable scenarios
- stable iPhone Mirroring window capture
- clear success metrics
- legal and reproducible setup
- low-cost recording and replay

Avoid early:

- competitive multiplayer games
- games with anti-cheat
- games with heavy camera control
- visually noisy 3D games
- games where progress depends mostly on long-term strategy
- games with random UI transitions that are hard to replay
- games requiring multi-touch, gyro, camera, or microphone

## Recommended Sequence

### 1. iPhone Mirroring Harness

Best first target.

Examples:

- local iPhone Safari test page
- simple tap target page
- simple swipe detector page
- local web microgame opened on iPhone
- harmless iPhone app screen with safe tap points

Why:

- measures the real iPhone Mirroring window path
- can log true visual-change time and input-received time
- can run locally without anti-cheat or purchase risk
- can intentionally create latency tests

Use this to prove:

- iPhone Mirroring capture loop
- latest-frame-wins behavior
- action engine
- synthetic tap/swipe controller
- content-rect calibration
- latency reporting
- replay traces
- screenshot vs model perception

Success metric:

- agent reacts to a controlled stimulus in under 100ms p95
- taps/swipes are recognized reliably
- agent can run for 5-10 minutes without stuck input

### 2. Simple iPhone Tap/Swipe Game

Best first real App Store game category.

Recommended types:

- tap-only games
- simple puzzle games
- card games
- turn-based games
- idle/clicker games
- one-finger swipe games

Why:

- real iPhone app behavior
- low action complexity
- safer than high-speed runners
- good for menus, retries, and visual-state parsing

Best fit:

- iPhone game adapters
- tap/swipe reliability
- safety guards
- screenshot perception

Tradeoff:

- less impressive than Subway Surfers, but much better for hardening the loop.

### 3. Subway Surfers

Best stress test once basic iPhone control works.

Why:

- fast endless runner
- small control set
- clear success metric
- latency-sensitive
- strongly visual

Use this after:

- iPhone Mirroring capture is stable
- synthetic left/right/up/down swipes are reliable
- game phase detection works
- purchase/ad/system-screen guards exist

See [13-subway-surfers-target.md](13-subway-surfers-target.md).

### 4. Controller-Supported iPhone Games

Best for testing generic controller support.

Why:

- avoids some touch coordinate problems
- maps well to a generic gamepad abstraction
- useful for wider game coverage

Tradeoff:

- Apple documents that wireless game controllers for iPhone apps should pair to the iPhone, not the Mac.
- A Mac-side virtual gamepad may not work through iPhone Mirroring.
- This likely needs a separate controller bridge backend.

See [15-gamepad-controller.md](15-gamepad-controller.md).

### 5. Browser/Emulator Games As Secondary Harnesses

These are useful for development, but not the product focus.

Use:

- local browser games to debug components faster
- Atari/Gymnasium to test policies
- emulators to test deterministic replay
- DOM games to test web-app automation

## Best First Choice

Start with an iPhone Mirroring harness: a local iPhone Safari page or very simple iPhone app/game that lets us measure tap/swipe response.

Make it instrumented from day one:

- render frame id on screen
- log stimulus timestamp
- log input received timestamp
- expose optional debug state when using a local page
- support deterministic reset
- support scripted scenarios

This gives three test modes in one target:

- pixel-only perception
- screenshot-to-model perception
- calibrated tap/swipe input

## Best Second Choice

Use a simple real iPhone tap/swipe game.

Why:

- real iPhone app surface
- manageable action space
- safer than Subway Surfers
- enough UI variation to exercise retries, menus, and failure handling

## Best Third Choice

Use Subway Surfers through iPhone Mirroring.

Why:

- it proves the system can handle fast visual mobile gameplay
- it stresses swipes, timing, perception, and latency
- it gives a compelling production proving ground

## Decision Matrix

| Target | Latency Proof | iPhone Realism | Perception Difficulty | Setup Risk | Recommendation |
| --- | --- | --- | --- | --- | --- |
| iPhone Safari harness | high | high | low | low | start here |
| iPhone tap game | medium | high | low-medium | low-medium | second |
| iPhone swipe puzzle/game | medium-high | high | medium | medium | second |
| Subway Surfers via iPhone Mirroring | high | high | high | medium-high | flagship target |
| Controller-supported iPhone game | high | high | medium | high | later backend |
| Local browser game | high | low-medium | low | low | support harness |
| Atari/Gymnasium | high | low | medium | medium | policy harness |
| Multiplayer iPhone game | high | high | high | very high | avoid |

## Target Profile Template

For each chosen game, write:

```text
name
source / install path
legal notes
window size
capture mode
perception mode
action space
success metric
latency target
reset method
replay method
safety constraints
known risks
```

## Immediate Recommendation

Build an iPhone Mirroring harness first.

Then run the same agent architecture against:

1. a simple iPhone tap game
2. a simple iPhone swipe game
3. Subway Surfers through iPhone Mirroring
4. controller-supported iPhone games once the controller backend is solved
5. browser/emulator targets only as supporting harnesses
