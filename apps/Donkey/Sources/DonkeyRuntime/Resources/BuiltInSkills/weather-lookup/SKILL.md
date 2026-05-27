# Weather Lookup
id: weather-lookup
description: Plan low-risk weather lookup workflows when a weather capability is provided.
tags: weather, lookup, local-app
tools: app.openOrFocus, app.observe, ui.focusSearch, ui.setText, ui.pressReturn, app.verifyVisibleText

Use this skill when a supported weather lookup definition or catalog capability is available.

Set the required location entity to the requested city or place. Use the task definition's entity name when it is more specific than `query`.

For search-style weather workflows, focus the search field, enter the normalized location, submit the search, and verify the visible result contains the requested place.
