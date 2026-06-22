# Safari

id: safari
description: Drive Safari through AppleScript — open, read, and manage tabs — falling back to AX/vision for in-page content and forms.
tags: browser, safari, web, tabs, local-app
keywords: browser, safari, web, url, tab, page, website, link, search, open
apps: Safari, com.apple.Safari
tools: shell_exec, app_skill

Safari is scriptable for navigation and tab management; in-page reading and form filling usually need the GUI tools.

## Navigate
- Open a URL (new tab in front window): `open https://example.com`.
- Navigate the current tab instead: `osascript -e 'tell app "Safari" to set URL of current tab of front window to "https://example.com"'`.
- Web search: `open "https://www.google.com/search?q=swift+concurrency"` (URL-encode the query).

## Read tab state
- Current page: `osascript -e 'tell app "Safari" to get URL of current tab of front window'` and `…get name of current tab…` for the title.
- All open tabs: `osascript -e 'tell app "Safari" to get name of every tab of front window'`.
- Find a tab by site: get every tab's URL, then act on the matching index.

## Manage tabs
- Close the current tab: `osascript -e 'tell app "Safari" to close current tab of front window'`.
- New window: `osascript -e 'tell app "Safari" to make new document'`.

## Capture the page
- Bookmark the current page: focus Safari and press Cmd+D, then return to accept the dialog.
- Save the page as PDF: GUI only — File → Export as PDF… via ax.observe on the menu bar.
- Screenshot the page to a file: `screencapture -x ~/Desktop/page.png` captures the screen (make Safari frontmost first); crop afterwards with `sips` if needed.
- Save title + URL elsewhere: read both via AppleScript above, then hand them to the Notes skill or `pbcopy`.

## History
- Recent history has no supported scripting path (the History database is private). Use the GUI: Cmd+Y opens History, then observe and drive the list; or re-open a known URL directly.

## In-page content and forms
- `do JavaScript` is gated behind Safari's Develop menu setting; do not rely on it. Read page content and fill forms through the GUI: focus Safari, vision.capture or ax.observe, then click/type on observed elements.
- Wait for pages to load before observing (`wait` 1–2s after navigation), and scroll (`mouse.scroll`) to reach content below the fold.

## Verify
- After navigation, re-read the current tab URL/title and confirm it matches the goal before completing.
