# Music Media
id: music-media
description: Plan low-risk media playback in Apple Music or another supported media app.
tags: media, music, playback, local-app
tools: app.openOrFocus, app.observe, ui.focusSearch, ui.setText, ui.pressReturn, app.verifyCommand, app.verifyVisibleText

Use this skill for play or listen requests when a supported media app or a `play_media` catalog capability is available.

For explicit songs, albums, or playlists, put the concrete playable title plus artist when known in `query`.

For vague artist or genre playback requests, choose one concrete representative song or album before returning task JSON. Do not use an artist-only query for playback unless the user explicitly asks to open an artist page, artist albums, artist radio, station, or another browsing surface. If you cannot choose a concrete representative playable item with high confidence, return clarification instead of a local app task.

Set `metadata.mediaSelection.kind` to `explicit_song`, `explicit_album`, `explicit_playlist`, `representative_song`, or `representative_album`. For representative choices, also set `metadata.mediaSelection.seed`, `metadata.mediaSelection.selectedTitle`, and a short `metadata.mediaSelection.reason`. The `query` must include the selected playable title, not only the artist or genre seed.

When planning generic `local_app_interaction`, use `targetAppName` and `entities.appName` from the supported catalog entry. Use `goal=play media`, `inputEntity=query`, `controlID=search`, `focusKey=Command+F`, and tools `app.openOrFocus`, `app.observe`, `ui.focusSearch`, `ui.setText`, `ui.pressReturn`, `app.verifyCommand`, `app.verifyVisibleText`. If visible results are present, prefer a playable song row matching the requested seed over artist, playlist, category, or unrelated rows.
