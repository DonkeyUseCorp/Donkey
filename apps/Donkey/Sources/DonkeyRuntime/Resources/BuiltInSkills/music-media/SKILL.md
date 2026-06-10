# Music Media
id: music-media
description: Plan low-risk media playback in Apple Music or another supported media app.
tags: media, music, playback, local-app
keywords: play, listen, music, song, track, tune, album, playlist, artist, band, audio, podcast, radio, pause, resume, volume
apps: Music, Apple Music, com.apple.Music
tools: app.openOrFocus, app.observe, ui.focusSearch, ui.setText, ui.pressReturn, app.verifyVisibleText
scripts: scripts-play-media-by-search

Use this skill for play or listen requests when a supported media app or a `play_media` catalog capability is available.

Playing media is a low-risk, reversible action: act directly, do not ask the user to confirm or for more detail. For a vague request (e.g. "play some coldplay") pick one concrete representative song yourself and play it; for a named song use it. Return the local app task with `needsConfirmation=false`. Only return clarification when no concrete song can be chosen at all.

First decide the playback source. Use `metadata.mediaSelection.source=local_library` only when the user explicitly asks for local, library, downloaded, or owned music. Otherwise use `metadata.mediaSelection.source=streaming`; Apple Music is normally a streaming catalog, so the workflow should search, find an actual playable streaming result, and play it.

For explicit songs, albums, or playlists, put the concrete playable title plus artist when known in `query`.

For vague artist, mood, or genre playback requests, choose one concrete representative song before returning task JSON. Do not choose a representative album, artist page, library item, station, or genre page when the user asks to play music. Do not use an artist-only query for playback unless the user explicitly asks to open an artist page, artist albums, artist radio, station, or another browsing surface.

Set `metadata.mediaSelection.kind` to `explicit_song`, `explicit_album`, `explicit_playlist`, or `representative_song`, and always set `metadata.mediaSelection.source` to `streaming` or `local_library`. For representative choices, also set `metadata.mediaSelection.seed`, `metadata.mediaSelection.selectedTitle`, and a short `metadata.mediaSelection.reason`. The `query` must include the selected song title and artist, not only the artist, album, genre, or mood seed.

Prefer the validated skill script path when the selected catalog entry supports it:

- This skill ships a validated script — `skillID=music-media`, `scriptID=scripts-play-media-by-search` — that searches Apple Music for the query and starts playback as one bounded step.
- Execute it with your skill-script execution tool (`skill.script.execute`, or `skill_run` in the fast command layer), passing the structured `query` as the script input.
- Verify the structured script evidence (`state.verify`, or the script's returned status fields); do not use screenshot verification unless the script cannot provide evidence.
- The script input must be the same structured `query`; never pass raw user text separately.
- Treat script output as structured evidence. `status=played` means the script submitted playback. `clarification.required=true` means stop and ask the included `clarification.question`.

The AppleScript script is bounded and deterministic. It must not use raw user text, shell commands, files, deletion, quitting apps, network commands, or unrelated applications. Keep the UI plan below as the fallback path when the skill script cannot execute or does not produce enough evidence.

When planning generic `local_app_interaction`, use `targetAppName` and `entities.appName` from the supported catalog entry. For the preferred script flow, use `skill.load`, `skill.script.execute`, and `state.verify`. For UI fallback, use `goal=play media`, `inputEntity=query`, `controlID=search`, `focusKey=Command+F`, and tools `app.openOrFocus`, `app.observe`, `ui.focusSearch`, `ui.setText`, `ui.pressReturn`, a second `ui.pressReturn`, and `app.verifyVisibleText`. The first Return submits the search; the second Return activates the top playable result. If visible results are present, prefer a playable song row matching the requested seed over artist, playlist, category, or unrelated rows.
