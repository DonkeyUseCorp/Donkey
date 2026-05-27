# Browser Navigation
id: browser-navigation
description: Plan opening websites and URLs in a supported browser.
tags: browser, website, navigation, local-app
tools: app.openOrFocus, app.observe, ui.focusAddressBar, ui.setText, ui.pressReturn, app.verifyCommand

Use this skill for website or URL navigation when the app finder catalog exposes a supported browser capability.

Set `query` to the normalized URL or website string to open. Prefer the user's named browser when present; otherwise choose a supported browser catalog entry.

When planning generic `local_app_interaction`, use `goal=open requested website`, `inputEntity=query`, `controlID=addressBar`, `focusKey=Command+L`, and tools `app.openOrFocus`, `app.observe`, `ui.focusAddressBar`, `ui.setText`, `ui.pressReturn`, `app.verifyCommand`.
