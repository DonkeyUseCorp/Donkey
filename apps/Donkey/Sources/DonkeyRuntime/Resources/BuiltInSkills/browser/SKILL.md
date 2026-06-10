# Browser

id: browser
description: Open websites in any browser — `open` for the default browser, `open -a` for a named one, Cmd+L + typing for in-browser navigation.
tags: browser, website, navigation, local-app
keywords: browser, website, url, open site, chrome, firefox, arc, edge
tools: shell_exec, app_skill

Opening a URL never needs GUI automation:

- Default browser: `open https://example.com`.
- A specific browser: `open -a "Google Chrome" https://example.com` (use `apps_list` to get the exact name).
- Web search: `open "https://www.google.com/search?q=URL+ENCODED+QUERY"`.

To navigate an already-open browser window instead of opening a new tab: focus the browser, press Cmd+L (keyboard.press key=l modifiers=command) to focus the address bar, type the URL with text.enter, then press return. `wait` 1–2s after navigation before observing the page.

Safari has its own richer skill (tab management, reading tab state via AppleScript) — prefer it when the browser is Safari. Chromium browsers also answer `osascript -e 'tell app "Google Chrome" to get URL of active tab of front window'` when installed.

Verify by re-reading the frontmost browser tab (AppleScript when scriptable, otherwise observe the window title).
