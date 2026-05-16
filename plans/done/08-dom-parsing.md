# DOM Parsing

> Archived status: historical context only. This file is not an active implementation queue. Supported behavior lives in `docs/`; future work from this idea needs a fresh active plan created deliberately.

## Goal

Use DOM state as a low-latency perception channel for browser games, web apps, and desktop software built on web views.

When available, DOM state can be faster and more reliable than computer vision:

- exact text instead of OCR
- element roles instead of visual guessing
- stable ids/classes/data attributes
- input values and checked states
- clickable targets and links
- layout bounds from the browser

DOM parsing should complement screen perception, not replace it entirely. Canvas-heavy games, WebGL games, videos, and custom-rendered UIs may still require pixels.

## Position In The Architecture

```text
Browser / WebView
  -> DOM Snapshot Or HTML String
  -> DOM Parser / Extractor
  -> DOM State
  -> World State
  -> Fast Controller
```

DOM extraction runs beside screen capture. Both should publish into the same world-state model.

## Recommended Default

Use `node-html-parser` for fast parsing of HTML snapshots:

Source: https://github.com/taoqf/node-html-parser

Why it fits this project:

- designed for performance
- produces a simplified DOM tree
- supports `querySelector` and `querySelectorAll`
- lightweight compared with full browser emulation
- good enough for extracting state from known pages or controlled game UIs

Example use:

```ts
import { parse } from "node-html-parser";

const root = parse(html);
const score = root.querySelector("[data-score]")?.textContent;
const buttons = root.querySelectorAll("button, [role=button]");
```

## Important Limitation

Parsing HTML is not the same as reading a live browser DOM.

If the page is dynamic, the HTML string may miss:

- runtime state stored in JavaScript
- canvas/WebGL content
- shadow DOM details
- computed layout
- event listeners
- transient animation state
- framework state not reflected in attributes or text

For browser-controlled targets, prefer live DOM queries or Chrome DevTools Protocol snapshots when possible.

## Decision Tree

1. If the target is a normal browser page and the agent can execute JavaScript in it, use live DOM queries first.
2. If the agent needs layout bounds, shadow DOM, or computed styles, use Chrome DevTools Protocol `DOMSnapshot.captureSnapshot`.
3. If the agent only has HTML strings or saved snapshots, use `node-html-parser`.
4. If strict browser-compatible parsing matters more than speed, use `parse5`.
5. If jQuery-style extraction is more productive than raw DOM traversal, use `cheerio`.
6. If a nearly complete DOM environment is needed, use `happy-dom` or `jsdom` outside the reflex loop.

## Alternatives

| Option | Best Use | Tradeoff |
| --- | --- | --- |
| Browser-native DOM APIs | fastest live state when inside the page | requires page execution or browser automation access |
| Chrome DevTools Protocol `DOMSnapshot.captureSnapshot` | DOM plus layout/style snapshots | Chrome-specific and snapshot payloads can be large |
| `node-html-parser` | fast HTML snapshot parsing | simplified DOM, not full browser behavior |
| `htmlparser2` | very fast streaming/callback parsing | lower-level API unless paired with DOM utilities |
| `parse5` | standards-compliant HTML parsing | usually heavier than performance-first parsers |
| `cheerio` | ergonomic jQuery-like extraction | useful API, but adds abstraction and may be slower than direct parsing |
| `linkedom` | lightweight DOMParser-style API | less battle-tested than `parse5`/`jsdom` for edge cases |
| `happy-dom` | faster browser-like DOM environment for tests/simulation | much heavier than a simple parser |
| `jsdom` | broad web standards emulation | too heavy for the hot path |

## Hot-Path Rules

- Extract only the selectors needed by the controller.
- Avoid reparsing the full DOM every frame.
- Keep selector lists explicit and small.
- Cache stable nodes or selector results when possible.
- Prefer incremental mutation signals when available.
- Keep full DOM snapshots out of the reflex loop unless measured and proven cheap.
- Drop stale DOM snapshots the same way stale video frames are dropped.

## DOM State Shape

Keep the parsed output compact:

```text
timestamp
page_url
scene_id
visible_text
interactive_elements
game_state_elements
form_values
selected_menu
layout_bounds
confidence
raw_source_id
```

Do not pass parser-specific nodes into the controller. Convert DOM data into the common world-state schema.

## Measurement

Track DOM parsing separately from visual perception:

- html_fetch_ms
- dom_snapshot_ms
- parse_ms
- selector_ms
- extraction_ms
- dom_state_age_ms
- dom_payload_bytes
- selected_node_count

Add these to the latency report so the team can compare:

- vision-only reflex loop
- DOM-only reflex loop
- hybrid DOM plus vision loop

## First Milestones

1. Add `node-html-parser` as the first HTML snapshot parser candidate.
2. Build a small extractor that maps selectors to world-state fields.
3. Benchmark parse time and selector time on representative pages.
4. Add a live DOM query path for browser-controlled targets.
5. Add CDP snapshot evaluation for pages where layout bounds matter.
6. Decide per target whether DOM, vision, or hybrid perception is fastest.

## Acceptance Criteria

- DOM extraction p95 is measured separately from visual perception.
- DOM-derived state can feed the same controller interface as vision-derived state.
- Full DOM parsing is not required on every frame unless it stays inside the latency budget.
- The chosen parser is justified by benchmark results on target pages, not generic package claims.
