# Web Capture

id: web-capture
description: Save a web page to a file — clean markdown via web.fetch, or a PDF or full-page screenshot of the rendered page.
tags: web, capture, pdf, screenshot, archive, markdown
keywords: save page, web page, website, pdf, screenshot, archive, markdown, capture, print to pdf
tools: web.fetch, web_snapshot, web.automate, shell_exec, apps_list

Pick the format the user asked for. Saving to a file is reversible; default the
destination to `~/Downloads`.

## Page to markdown or JSON — use web.fetch, not a browser
- `web.fetch` returns the page's main content as clean markdown already. Save it with the `web-research`/`notes` long-content pattern.
- For JSON, pass the fetched markdown through `llm.generate` ("structure this as JSON with fields …"). Do not screenshot or drive a browser for text.

## Page to PDF or screenshot — render it (free rungs first)
Capture the rendered page with the cheapest engine that works, in order:
1. **Local Chromium**, only if one is installed — check `apps_list` (Google Chrome, Brave, Microsoft Edge, Arc), then `'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' --headless=new --disable-gpu --print-to-pdf=$HOME/Downloads/page.pdf 'URL'` (PDF) or `--screenshot=$HOME/Downloads/page.png --window-size=1280,2000 'URL'`.
2. **Built-in `web_snapshot`** — always available, no external browser. `web_snapshot` with `url` and `format=pdf` (default) or `format=png` (full page), optional `destination`. Use this whenever no Chromium is installed.
3. **Hosted browser (`web.automate`)** — for a page behind a login or heavy bot-protection that the free engines can't render. It drives a real cloud browser and spends the user's credits, so confirm first. See the `web-automation` skill.

Do not invent a headless flag for Safari; it has none. For just the visible
screen rather than the whole page, `screencapture -x ~/Downloads/shot.png` after
making a browser frontmost.

## Verify
- Markdown: confirm the saved file is non-empty and has the expected headings.
- PDF: `qpdf --show-npages page.pdf` (see the `pdf` skill) or open it. PNG: `sips -g pixelWidth -g pixelHeight page.png`.