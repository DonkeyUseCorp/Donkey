# Web Research

id: web-research
description: Find current facts on the web and read pages — search, then fetch and read — feeding the result into notes, messages, or other tasks.
tags: web, search, research, internet, lookup
keywords: search, look up, google, latest, news, who is, what is, current, find online, website, article, lyrics, tracklist
tools: web.search, web.fetch, llm.generate

Use this whenever a task needs information you can't be sure of from memory — anything "latest", "current", "today", a specific person/product/place, song lyrics, an album's tracklist. Do NOT guess, and do NOT drive a browser's GUI for this; the web tools are faster and reliable.

## The loop
1. `web.search` with a focused query → ranked results (title — URL, snippet). Read the snippets.
2. `web.fetch` the most relevant URL to read the page in full. For a long page, set `toFile=true` and work from the returned file.
3. Use `llm.generate` to distill what you read into exactly what the task needs (a clean list, a summary, a tracklist), `toFile=true` for long output.
4. Hand the result to the destination step (create a note from the file, send a message, etc.).

## Examples
- "Taylor Swift's latest album and its songs": `web.search "Taylor Swift latest album 2026"` → fetch the album page → `llm.generate "From this page, list every track, one per line" toFile=true` → create the note from the file (see the notes skill's long-content pattern).
- "What's the weather in Tokyo": `web.search "Tokyo weather today"` and read the snippet.
- "Lyrics for <song>": search → fetch a lyrics page → distill with llm.generate.

## Boundaries
- Reading the web is safe and runs without consent. The tools only GET pages; they never submit forms, log in, or post.
- If `web.search` is unavailable (not configured), say so plainly; `web.fetch` still works for a URL the user gives.
