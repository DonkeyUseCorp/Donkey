# Donkey Vision

## What It Is

Donkey Vision is the observation layer that helps Donkey understand what is on a
user's computer screen well enough to reason about it. It is not a single model
or a single provider. It is a fusion system: local Mac evidence gives Donkey
grounded geometry, and AI helps interpret what those grounded regions mean.

The practical goal is simple: when Donkey needs to navigate around a user's
computer, it should know where UI elements are, what they probably are, and how
confident it should be. The answer should be useful without pretending that a
vision model's bounding boxes are perfect.

## Why Fusion Exists

No single source is enough.

Accessibility is the best source when an app exposes good native controls. It
can give precise bounds, roles, labels, and supported actions. But many modern
desktop apps are web or Electron shells, and their Accessibility trees can be
sparse, grouped, stale, or missing important icon controls.

Screenshots see what the user sees. Native visual detection can find shapes,
rows, panels, input surfaces, and icon-like regions from pixels. It is useful for
geometry, especially when Accessibility is thin, but it does not always know the
semantic name of a control.

AI can read the scene and recognize likely UI concepts across apps. It can say
"this looks like a search field", "this row is a project", or "this icon is a
voice button." But AI bounding boxes are approximate. They can be off by a few
pixels, too large, shifted to adjacent text, or attached to the wrong nearby
region. AI boxes are evidence, not authority.

Donkey Vision combines these strengths:

- Accessibility provides trusted local structure when available.
- AI provides semantic enrichment and fills gaps.
- Fusion decides which evidence should render or feed downstream reasoning.

## Geometry Rule

Local geometry wins.

If Donkey has a grounded local box from Accessibility or window chrome
geometry, that box should be preferred over an overlapping AI box. AI may enrich
the label or explain what the region probably means, but it should not replace
precise local geometry with a model-estimated rectangle. Native screenshot CV is
not part of the live Donkey Vision overlay pipeline.

This is especially important for:

- macOS traffic-light controls and titlebar buttons
- sidebars and navigation rows
- search fields and command inputs
- bottom composers and submit controls
- small icon-only toolbar buttons
- repeated list rows where nearby text can confuse model localization

AI-only boxes are still useful when no local evidence covers that part of the
screen. They should be marked as AI/read-only evidence so maintainers can see
that the position came from the model.

## Safety Boundary

Donkey Vision is observation. It does not authorize live input by itself.

Vision evidence can help Donkey plan, explain, debug, and decide where to look
next. Live input still has to pass through the guarded action boundary: target
validation, focus checks, permission policy, action eligibility, and runtime
verification.

AI-derived evidence is especially constrained:

- AI boxes are read-only evidence.
- AI output must not enable direct clicks, typing, scrolling, or dragging.
- Screenshots sent to hosted AI must be scoped to an app/window or a
  system-navigation surface, never the full desktop.
- Screenshots are not persisted or logged as general product data.

## Developer Overlay

The developer overlay is a way to see Donkey Vision while debugging. It should
render multiple evidence sources at the same time, with visible source badges:

- `AX` for Accessibility-backed boxes
- `AI` for hosted AI boxes

The distinction matters. If an `AI` box is visibly off, that is expected model
localization error and should not be fixed by adding arbitrary coordinate
offsets. Prefer improving local geometry, fusion, or the screenshot scope. If an
`AX` box is off, that is a local coordinate mapping bug and should be fixed in
the Mac geometry path.

The debug config uses Donkey Vision as the mode:

```json
{
  "enabled": true,
  "mode": "donkeyVision",
  "cadenceSeconds": 1.0,
  "screenScope": "main",
  "minConfidence": 0.25,
  "activeWindowOnly": true
}
```

Do not add a provider field to this config. Donkey Vision is always local AX
evidence plus hosted AI enrichment; the config controls cadence, scope, and
filters, not which evidence source runs.

## Source Map

High-signal entry points:

- `apps/Donkey/Sources/Donkey/LocalUIElementDetection/DebugUIInspectionCoordinator.swift`
- `apps/Donkey/Sources/Donkey/LocalUIElementDetection/DebugUIInspectionOverlayController.swift`
- `apps/Donkey/Sources/DonkeyAI/DebugUIInspectionFrameFusion.swift`
- `apps/Donkey/Sources/DonkeyAI/ScreenshotParseDebugUIOverlayMapper.swift`
- `apps/Donkey/Sources/DonkeyRuntime/LocalUIElementDetection/LocalUIElementDetectionService.swift`
- `site/src/lib/inference/screenshot-parsing/`

## Maintainer Rules

- Do not treat model boxes as pixel-perfect.
- Do not add global coordinate offsets to compensate for AI localization.
- Do not send full-desktop screenshots to hosted AI.
- Do not make provider selection the UI or config model for Donkey Vision.
- Prefer app/window-scoped screenshots and local geometry.
- Keep AI evidence marked and visually distinct.
- Keep live input authorization separate from visual evidence.
