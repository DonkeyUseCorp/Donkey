# Design

id: design
description: Create an image from scratch about any topic by designing it as code — infographics, explainers, diagrams, standings/brackets, charts, profiles, posters, cards. Write a self-contained HTML/SVG document, then render it to a crisp PNG with image_render. This is the reliable way to make a "nice image" of text, data, or knowledge.
tags: design, infographic, diagram, chart, poster, explainer, visual
keywords: image, infographic, explainer, diagram, chart, graph, poster, flyer, card, certificate, banner, visualize, visualization, visualisation, draw, drawing, design, graphic, illustrate, standings, table, bracket, leaderboard, timeline, roadmap, profile, summary, learn, teach, overview, nice, pretty, beautiful, clean
tools: image_render, web.search, web.fetch, llm.generate, files.describe

When someone wants "an image" / "an infographic" / "a nice diagram" about something —
sports standings, an election result, a person's profile, the solar system, how a
system works, a comparison, a poster — you design it yourself: write one HTML/SVG
document and render it with `image_render`. Do NOT screenshot a web page (that is
someone else's cluttered layout) and do NOT use `image.generate` (a generative model
garbles text and numbers). Rendering your own markup keeps every label sharp and gives
you full control of the layout. This works for ANY topic.

## The loop
1. Gather the content. For anything current or factual you're not sure of (today's
   standings, an election result, a player's stats), use `web.search` → `web.fetch`,
   then keep only the handful of facts the image needs. For general knowledge (the
   planets, a concept) you may already have it. Use `llm.generate` to distill messy
   source text into a clean, structured set of facts (`toFile=true` for a lot).
2. Decide the design before writing markup. In one sentence: the ONE thing this image
   should get across, the layout that carries it (a ranked list, a grid of cards, a
   bracket, a labelled diagram, a stat block, a timeline), and a small deliberate
   palette + type scale. Match the structure to the subject — a profile is not a table.
3. Write a single self-contained HTML document. Inline ALL CSS. Use system fonts
   (`-apple-system, "Helvetica Neue", Arial, sans-serif`) — remote fonts and images do
   not load. Embed any image/flag/logo as a `data:` URI, or use emoji (🇰🇷 ⚽ 🪐). Use
   inline `<svg>` for diagrams, brackets, arrows, gauges, and precise shapes. Wrap
   everything in a fixed-width container matching the width you'll render at.
4. Render it: `image_render` with your `html`, a `width`, and an optional `height`.
   Omit `height` to fit the content; default canvas is 1200px wide.
5. Verify and present: confirm the file exists (`files.describe`), then show it.

## Make it nice — this is the whole point
- Commit to a real visual concept, not a default box of text. A tournament group stage
  → a grid of group cards, each a small standings table with rank, flag, points, the
  leader highlighted. An election → a result bar or hemicycle of seats per party with a
  headline winner. A person → a profile card: name, role, a key-stat strip, a short
  bio, a few highlights. The solar system → a row of planets scaled and labelled with
  one or two facts each. A process → labelled boxes and arrows in inline SVG.
- Hierarchy: one strong title, a quiet subtitle (e.g. "as of <date>" or a source),
  then the content. Big size contrast between title and body.
- Restraint: one accent color plus neutrals; consistent padding; aligned columns;
  rounded corners and a soft shadow if they help. No rainbow palettes, no clutter.
- Size for the content, never a giant scroll: a wide dashboard (1600×900), a tall
  poster (1080×1350), a card (1200×630), a square (1080×1080).

## Examples
- "current fifa standings as a nice image" → fetch the ranking → titled card grid or a
  clean ranked table with flags + points → `image_render` width=1200.
- "infographic about the current local election in Korea" → fetch results → a seats/
  vote bar per party, headline result, turnout stat → `image_render` width=1200.
- "infographic about Son Heung-min" → fetch/recall key facts → a profile card: photo
  area (emoji/initials if no image), club, position, a career-stats strip, highlights.
- "I want to learn about the solar system" → an explainer: a scaled planet row, each
  with name + 2 facts, a legend, a short intro line → tall or wide canvas.

## When NOT to use this
- A real photo or piece of art ("a watercolor fox", "a sunset photo") → `image.generate`.
- Editing an existing photo → `image.edit`.
- The user explicitly wants a screenshot of a real web page → `web_snapshot`.
