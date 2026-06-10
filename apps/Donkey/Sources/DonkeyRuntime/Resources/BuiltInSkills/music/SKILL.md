# Music

id: music
description: Play music locally in Apple Music — never a web player — using the validated playback script.
tags: media, music, playback, local-app
keywords: play, listen, music, song, track, tune, album, playlist, artist, band, audio, podcast, radio, pause, resume, volume
apps: Music, Apple Music, com.apple.Music
tools: shell_exec, skill_run

Use this for "play …" / "listen to …" requests. Playing music is low-risk and reversible — act directly, don't ask the user to confirm. Always play **locally in the Music app**; never open YouTube Music, Spotify web, or any web player.

## Play with the validated script (preferred)

This skill ships a validated script — `skillID=music`, `scriptID=scripts-play-media-by-search` — that searches the Music app for a query and starts playback in one step (it tries the user's local library first, then the Apple Music streaming catalog). Run it with `skill_run`, passing the query as the input.

Choosing the query is what matters:

- **Vague artist / mood / genre request** ("play some coldplay", "play coldplay"): pass the **artist or seed word alone** as the query — e.g. `Coldplay`. A broad term matches whatever the user owns, so playback starts from their library. Do NOT over-specify with a particular song title the user didn't name; a title they don't own (and the word "by") makes the local match miss.
- **A specific named song/album**: pass the plain `Title Artist` (e.g. `Yellow Coldplay`) — space-separated, no "by".

Read the script's returned status:
- `status=played` → playback started; tell the user what's playing (`playedTitle`/`playedArtist`).
- `status=not_found` with `clarification.required=true` → only then ask the included question (e.g. the term isn't in the library and streaming didn't start).

Verify with the script's own status fields or `osascript -e 'tell application "Music" to player state'`; don't use screenshots.

## Direct AppleScript (when you don't run the script)

- Play whatever Coldplay is owned: `osascript -e 'tell application "Music" to play (item 1 of (search library playlist 1 for "Coldplay"))'`.
- Transport: `osascript -e 'tell application "Music" to playpause'`, `… to pause`, `… to set sound volume to 60`.
- What's playing: `osascript -e 'tell application "Music" to (get name of current track) & " — " & (get artist of current track)'`.

## GUI fallback

Only if scripting can't play it: focus Music, Cmd+F to search, type the query, press Return to submit and again to play the top result, then confirm `player state` is playing.
