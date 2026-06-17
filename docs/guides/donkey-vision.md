# Donkey Vision

Donkey Vision is the observation layer that turns the user's windows into
structured UI understanding the agent can reason about. It is not one model or
one provider — it is a fusion system: local Mac evidence gives grounded
geometry, and hosted AI enrichment interprets what those grounded regions
mean. The engine runs always-on and headless in production; the developer
overlay is just a window into it.

**The one rule:** local geometry wins. If a grounded local box exists from
Accessibility or window-chrome geometry, an overlapping AI box may enrich its
label but never replaces its rectangle. If an AI box is visibly off, do not
"fix" it with coordinate offsets — improve local geometry, fusion, or the
screenshot scope instead.

## How It Works

```text
frontmost-window monitor (screenshot fingerprint, re-parses on large change)
  |
  v
UIUnderstandingCoordinator captures the changed window
  |- Accessibility read: roles, labels, precise bounds, supported actions
  |- native visual detection: shapes, rows, panels, icon regions from pixels
  |- hosted vision parse (POST /api/vision) only when that window's pixels
  |  changed since the last successful parse; unchanged windows reuse their
  |  carried-forward boxes
  v
fusion: local geometry wins; AI enriches labels and fills uncovered gaps
  |
  v
WindowUIUnderstandingStore (per-window cache)
  |
  v
the agent's captureAndAnalyze reads the store first; the debug overlay
renders the same evidence when enabled
```

Local evidence decides *where* things are; AI decides *what* they probably
mean. Fusion decides which evidence renders or feeds downstream reasoning.

Each source covers the others' blind spots. Accessibility is precise when an
app exposes native controls, but web and Electron shells leave it sparse or
stale. Native visual detection finds geometry in any pixels but not semantic
names. Hosted AI recognizes UI concepts across apps ("this is a search field",
"this icon is a voice button") but its bounding boxes are approximate — off by
pixels, too large, or attached to nearby text. AI boxes are evidence, not
authority.

An older streaming screenshot-parse path is kept compiled behind the
coordinator's `remoteAIEngine` switch, which is currently hardcoded to the
vision path.

## Safety Boundary

Donkey Vision is observation first; it can also supply a secondary live-input
target when Accessibility cannot provide a better element. Live input always
passes through the guarded action boundary: target validation, focus checks,
permission policy, action eligibility, and runtime verification. Input tries
Accessibility first, then AI visual targets, then guarded coordinate click
fallback.

AI-derived evidence is specially constrained:

- AI boxes may be interactable only when they come from a scoped app/window or
  system-navigation screenshot and are marked `guardedAction`.
- AI output may provide a coordinate click target only after the Accessibility
  path fails or is unavailable; the executor clicks the guarded target center,
  never an unbounded desktop coordinate.
- Screenshots sent to hosted AI must be scoped to an app/window or a
  system-navigation surface, never the full desktop.
- Screenshots are not persisted or logged as general product data.

## Developer Overlay

The overlay renders the live fusion result for debugging, with a visible
source badge on every box:

| Badge | Source | If a box is off |
|---|---|---|
| `AX` | Accessibility | local coordinate mapping bug — fix the Mac geometry path |
| `CV` | native visual detection | local detector issue — fix detection, not offsets |
| `AI` | hosted vision parse | expected model localization error — never add coordinate offsets |

The overlay is enabled through `dev-overlay.json` (see
`docs/guides/user-query-overlay.md` for where the config lives):

```json
{
  "enabled": true
}
```

`enabled` is the only knob: it flips the visible overlay on or off. Cadence,
scope, confidence, and app filters are fixed sensible defaults in code, not
config. Do not add a provider field either — Donkey Vision is always local
evidence plus hosted AI enrichment.

## Source Map

| Path | Owns |
|---|---|
| `apps/Donkey/Sources/Donkey/LocalUIElementDetection/UIUnderstandingCoordinator.swift` | always-on engine: capture, change detection, parse scheduling |
| `apps/Donkey/Sources/Donkey/LocalUIElementDetection/DebugUIInspectionOverlayController.swift` | debug overlay rendering and badges |
| `apps/Donkey/Sources/DonkeyAI/DebugUIInspectionFrameFusion.swift` | fusion of local and AI evidence |
| `apps/Donkey/Sources/DonkeyAI/VisionParseDebugUIOverlayMapper.swift` | active AI source mapping |
| `apps/Donkey/Sources/DonkeyAI/ScreenshotParseDebugUIOverlayMapper.swift` | retained, disabled streaming path |
| `apps/Donkey/Sources/DonkeyRuntime/LocalUIElementDetection/LocalUIElementDetectionService.swift` | native visual detection |
| `site/src/lib/inference/vision/`, `site/src/lib/inference/screenshot-parsing/` | backend vision parsing |

## Maintainer Rules

1. **Model boxes are never pixel-perfect.** Do not add global coordinate
   offsets to compensate for AI localization.
2. **Smallest scope that works, escalate when needed.** Screenshots may go to
   hosted models (the harness sends compressed captures to multimodal models).
   Start with the target window; widen to a display for cross-window surfaces
   like modals; fall back to the whole desktop only when the thing to act on
   isn't visible at a tighter scope. Always compress before sending, and prefer
   the tightest scope that still shows what the model needs.
3. **No provider switch.** Provider selection is not the UI or config model
   for Donkey Vision.
4. **AI evidence stays marked.** Keep AI boxes visually distinct and tagged so
   maintainers can see the position came from a model.
5. **Guarded input only.** AI visual targets drive coordinate clicks only
   after focus, permission, target-window, and action-eligibility checks pass.
