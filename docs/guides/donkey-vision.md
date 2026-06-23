# Donkey Vision

Donkey Vision is how the agent sees pixels that structured Accessibility reads
miss — canvas, Electron, web shells, custom-drawn controls. It is a tool the
agent calls, not a background service. When the planner decides during a run
that structured reads aren't enough, it captures the target window and a hosted
vision model parses the screenshot into labeled, located UI elements it can then
click.

There is no always-on engine. Vision work only ever happens inside a live run,
on the planner's own decision, so an idle app spends nothing on the screen. A
question comes in, the planner decides whether it needs to look, and only then
is a screenshot taken and parsed.

## How It Works

The agent calls one tool — `vision.capture` — when it decides to look:

```text
planner decides it needs to see pixels AX missed
  |
  v
vision.capture captures the target
  |- scope=window  (default): the frontmost window
  |- scope=screen           : the whole display, for a modal/sheet/menu drawn
  |                           outside the window
  |- scope=desktop          : all displays, for a target on another monitor
  v
hosted vision parse (POST /api/vision) turns the screenshot into located,
labeled elements
  |
  v
world model: each element with its geometry and click eligibility; a later
vision.click maps it back through the window's current bounds
```

Within one run, a re-capture of an unchanged window reuses the previous parse
instead of paying for another — the tool signature-matches the screenshot
against the parse it wrote on its last capture (`ParsedVisionStore`). Across
runs nothing is carried forward and nothing is kept warm.

Vision complements Accessibility rather than replacing it; they are separate
tools the planner picks between. Accessibility is precise when an app exposes
native controls but goes sparse or stale on web and Electron shells. Hosted
vision recognizes UI concepts across any pixels ("this is a search field", "this
icon is a voice button"), but its bounding boxes are approximate — off by
pixels, too large, or attached to nearby text. So vision boxes are evidence the
planner acts on, not pixel-perfect truth.

## Safety Boundary

Vision is observation first; a parsed element can also become a live-input
target when Accessibility cannot provide a better one. Live input always passes
through the guarded action boundary: target validation, focus checks, permission
policy, action eligibility, and runtime verification. Input tries Accessibility
first, then a vision target, then a guarded coordinate click.

AI-derived evidence is specially constrained:

- A vision element may drive a coordinate click only after the Accessibility
  path fails or is unavailable; the executor clicks the element's mapped center,
  never an unbounded desktop coordinate.
- Screenshots sent to the hosted model are scoped to an app/window or a
  system-navigation surface, never the full desktop as a routine default.
- Screenshots are not persisted or logged as general product data.

## Developer Overlay

The developer overlay is a separate debug tool, not part of the agent's vision
path. When enabled, it runs its own engine that parses the screen to draw boxes
over live UI, fusing two local sources of geometry — Accessibility and native
visual detection — with the hosted AI parse. Its one rule is **local geometry
wins**: where a grounded local box exists, an overlapping AI box may enrich its
label but never replaces its rectangle. If an AI box is visibly off, do not
"fix" it with coordinate offsets — improve local geometry, fusion, or the
capture scope instead.

The overlay is decoupled from the agent by construction: it parses only while it
is enabled, it never feeds the agent, and the agent never reads from it. It
exists only in debug-overlay builds, and even there it draws (and parses) only
when `dev-overlay.json` turns it on:

```json
{
  "enabled": true
}
```

`enabled` is the only knob. Each box carries a source badge:

| Badge | Source | If a box is off |
|---|---|---|
| `AX` | Accessibility | local coordinate mapping bug — fix the Mac geometry path |
| `CV` | native visual detection | local detector issue — fix detection, not offsets |
| `AI` | hosted vision parse | expected model localization error — never add coordinate offsets |

See `docs/guides/user-query-overlay.md` for where the config lives.

## Source Map

| Path | Owns |
|---|---|
| `apps/Donkey/Sources/DonkeyAI/VisionComputerUseTools.swift` | the agent's on-demand `vision.capture`/`vision.click` tools and within-run parse reuse |
| `apps/Donkey/Sources/Donkey/LocalUIElementDetection/UIUnderstandingCoordinator.swift` | debug overlay engine: capture, change detection, parse scheduling |
| `apps/Donkey/Sources/Donkey/LocalUIElementDetection/DebugUIInspectionOverlayController.swift` | debug overlay rendering and badges |
| `apps/Donkey/Sources/DonkeyAI/DebugUIInspectionFrameFusion.swift` | fusion of local and AI evidence for the overlay |
| `apps/Donkey/Sources/DonkeyAI/VisionParseDebugUIOverlayMapper.swift` | AI parse → overlay element mapping |
| `apps/Donkey/Sources/DonkeyRuntime/LocalUIElementDetection/LocalUIElementDetectionService.swift` | native visual detection |
| `site/src/lib/inference/vision/` | backend vision parsing |

## Maintainer Rules

1. **Vision is on-demand and run-scoped.** It happens only inside a live run,
   when the planner chooses to look. Do not reintroduce a background warm loop,
   an always-on parse engine, or any path that parses the screen while no run is
   asking for it.
2. **Model boxes are never pixel-perfect.** Do not add global coordinate offsets
   to compensate for AI localization.
3. **Smallest scope that works, escalate when needed.** Start with the target
   window; widen to the display for modals; fall back to the whole desktop only
   when the target isn't visible at a tighter scope. Always compress before
   sending.
4. **No provider switch.** Provider selection is not a UI or config concept for
   Donkey Vision.
5. **The overlay stays decoupled.** It is a debug visualization only — keep it
   from feeding the agent or becoming a vision source the agent depends on.
6. **Guarded input only.** A vision target drives a coordinate click only after
   focus, permission, target-window, and action-eligibility checks pass.
