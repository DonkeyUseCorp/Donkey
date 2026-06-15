# Music

id: music
description: Play and control Apple Music natively with the music.* tools — playback never uses the Music app GUI, AppleScript, or a web player. Deleting a playlist is the lone exception: no API exists, so it is done through the GUI with the general see/act tools.
tags: media, music, playback, local-app
keywords: play, listen, music, song, track, tune, album, playlist, artist, band, audio, radio, pause, resume, skip, volume, shuffle, repeat, queue, seek, rewind
apps: Music, Apple Music, com.apple.Music
tools: music.play, music.search, music.transport, music.status, music.playlist, shell_exec, web.search

Use this for any music request: playing tracks/albums/artists/genres, transport (pause, skip, what's playing), and the user's own playlists.

Playback goes entirely through the native music tools — for playback never launch, focus, script, or click the Music app, and never open YouTube, Spotify web, Apple Music web, or any browser player. (Deleting a playlist is the one task that does use the Music GUI — see Playlists.)

## Step 1: Pick the tool

1. Play anything (track, album, artist, playlist, genre, mood, era) → `music.play`.
2. Queue something to play next or after the queue ("play X next", "add X to the queue") → `music.play` with `enqueue`.
3. Transport (pause, resume, skip, previous, stop, fast-forward, rewind, seek, shuffle, repeat) → `music.transport`.
4. Volume → system volume via `shell_exec` (see below).
5. What's playing → `music.status`.
6. The user's own playlists (list, create, add songs, read contents) → `music.playlist`.

## Step 2: Resolve the query when needed

Most requests pass straight to `music.play`. Use web.search (or llm.generate for pure music knowledge) ONLY when information is missing or indirect: "latest album from X", "song from <movie/show/game>", "the song that goes <lyrics>". Convert the result into a compact query, include the artist when it reduces ambiguity, and don't mention the search step unless playback fails. If resolution is uncertain, still make the best reasonable attempt.

## Step 3: Play

`music.play` with `query` = the music in plain words. It plays the user's own library first (owned or downloaded content, which needs no subscription), then falls back to the catalog, playing the top match and preferring songs. Steer it with `kind` when the request names a shape: `kind=album` for albums, `kind=playlist` or `kind=station` for hits/genre/mood/era requests. When the right item is ambiguous enough to matter, run `music.search` first and play an exact result with `kind`+`id`.

Good queries: `baby don't cry` · `my heart will go on celine dion` · `coldplay` · `top 80s hits` · `abbey road beatles`.
Bad queries: `play baby don't cry` · `listen to coldplay` — no command phrases, and no "by" unless it is part of the actual title.

## Step 4: Trust the tool's verification

A successful `music.play` already verified playback — position was sampled until it advanced; report what's playing and `run.complete` without re-verifying. A failure summary names the exact cause (permission, no subscription, signing/token, item unavailable) — relay it plainly.

## Transport, volume, now playing

- Transport: `music.transport` with `action` = `pause` | `resume` | `stop` | `next` | `previous`.
- Fast-forward / rewind: `action=forward` or `action=rewind`, `seconds` optional (default 15). Jump to a spot: `action=seek` with `seconds` from the start ("skip the intro" → seek to ~30–60s, "start over" → seek to 0).
- Shuffle: `action=shuffle` `mode=on|off`. Repeat: `action=repeat` `mode=off|one|all`.
- Queue: "play X next" / "then play X" → `music.play` with `enqueue=next` (or `enqueue=last` for the end of the queue) — the current song keeps playing. Stations can't be queued, only played.
- Volume: set the Mac's output volume with `shell_exec` → `osascript -e 'set volume output volume 60'` (system volume, not the Music app — never script the Music app for anything).
- Now playing: `music.status`. Position advancing is the only trustworthy "it is playing" signal — never trust a status string alone.
- Boundary: the `music.*` tools control ONLY playback this assistant started. If `music.status` shows nothing playing but the user says music is audible, that audio was started manually in the Music app — say so and let the user control it there. Never script or click the Music app, even then.

## Playlists

- "play my X playlist" → `music.playlist` action=list, match the name from the typed results, then `music.play` kind=playlist id=<that id>.
- "make me a playlist" → `music.playlist` action=create with a name; to fill it, find ALL the song ids in ONE `music.search` call with the queries separated by " | " (they run concurrently — never search one song per step), then one `music.playlist` action=add with the ids comma-separated in `songIDs`.
- "add this song to X" → the currently playing song's id is in the world model facts (`music.playing.id`) when this run started it; otherwise `music.search` for it. Then action=add.
- "what's in X" → action=entries.
- A successful create/add is confirmed by the Apple Music API — that is the evidence; report it and complete. Use action=entries only when the user asks what's inside.
- Removing individual tracks and renaming have no Apple API and no GUI path worth driving — say so plainly, point the user to the Music app, don't fake success.
- Deleting a WHOLE playlist has no API (no MusicKit delete; AppleScript `delete playlist` errors -1708), so do it in the GUI with the general row tool, in one call: `ax.select_and_press` with `label=<playlist name>`, `key=delete`, `confirm=Delete`. That selects the sidebar row, presses Delete, and confirms the dialog atomically; then `ax.observe` to verify the row is gone. The sidebar is the source of truth, not `music.playlist action=list` (the MusicKit list can lag). If the row isn't found, the playlist was just created and hasn't synced from iCloud yet — `wait` briefly and retry.

## Failure behavior

Never open a web player; never drive the Music GUI for playback (deleting a playlist is the lone sanctioned GUI use). The tool's failure summary names the exact blocker — pass it on, e.g. "I couldn't start playback: this Mac's Apple ID has no active Apple Music subscription."

## Response style

Success: "Playing **{title}** by **{artist}**." Album: "Playing **{album}** by **{artist}**." Playlist/station: "Playing **{playlist/station}**." Transport/volume: "Paused." / "Resumed." / "Volume set to 60%." Keep responses short — the action matters more than the explanation.
