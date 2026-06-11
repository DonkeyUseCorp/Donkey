# Music

id: music
description: Play music locally in Apple Music — never a web player — using the validated playback script first, then UI fallback only when needed.
tags: media, music, playback, local-app
keywords: play, listen, music, song, track, tune, album, playlist, artist, band, audio, radio, pause, resume, skip, volume
apps: Music, Apple Music, com.apple.Music
tools: skill_run, shell_exec, vision.capture, vision.click, web.search

Use this for any music playback request: "play baby don't cry", "play top 80s hits", "play the latest album from Taylor Swift", "play something by Coldplay", "play the song from Titanic", "play relaxing piano music", "pause the music", "turn it up", "what's playing?".

Playback is low-risk and reversible: act directly, don't ask for confirmation. Always play locally in the Music app; never open YouTube, Spotify web, Apple Music web, or any browser player. Convert the request into the best Apple Music search query, then play it. Prefer the most likely mainstream interpretation. Do not over-explain — the user wants the music to start.

## Step 1: Classify the playback intent

1. play_track — a specific song or likely song.
2. play_album — an album.
3. play_artist — an artist, or "something by" an artist.
4. play_playlist_or_station — hits, genre, mood, era, playlist, radio, "music like X".
5. transport_control — pause, resume, skip, previous, stop.
6. volume_control — louder, quieter, set volume.
7. now_playing — what is currently playing.

For transport_control, volume_control, and now_playing use direct AppleScript (commands below) — never run a search for these. For all play intents run the validated script first, unless the request needs external resolution.

## Step 2: Resolve the query when needed

Most requests pass straight to the script. Use web.search (or llm.generate for pure music knowledge) ONLY when information is missing or indirect: "latest album from X", "new song by X", "song from <movie/show/game>", "song that goes <lyrics>", "the viral song that says …", "top song by X", "the original version of …". Prefer reliable music sources (artist discographies, Wikipedia, Genius, MusicBrainz). Convert the result into a compact Apple Music query, include the artist when it reduces ambiguity, and don't mention the search step unless playback fails.

Examples: "play the latest album from Taylor Swift" → resolve the current latest album → `<that album> Taylor Swift`. "play the song from Titanic" → `My Heart Will Go On Celine Dion`. "the song that goes never gonna give you up" → `Never Gonna Give You Up Rick Astley`.

If resolution is uncertain, still make the best reasonable attempt.

## Step 3: Run the validated script

`skill_run` with `skillID=music`, `scriptID=scripts-play-media-by-search`, input = the normalized query in plain words. The script plays from the user's library when they own a match (instant); otherwise it resolves the most popular catalog match for the query, deep-links straight to that track in Music, starts playback, and verifies playback really started before claiming success.

Good inputs: `baby don't cry` · `my heart will go on celine dion` · `coldplay` · `top 80s hits` · `abbey road beatles`.
Bad inputs: `play baby don't cry` · `listen to coldplay` — no command phrases, and no "by" unless it is part of the actual title.

## Step 4: Read the script status (the source of truth)

- `status=played` → playback started and was verified. Tell the user briefly what is playing, using `playedTitle`/`playedArtist`.
- `status=not_found` → read the script's `hint=` field; it states what happened and what to do next. Do NOT re-run the same query, and do not focus/open/activate Music — the script already left the right page on screen. If the hint suggests a visual click, do `vision.capture` then `vision.click` on the named song row, then verify playback. If it still won't start, say the likely reason plainly instead of retrying.
- Script error → don't loop. Try one improved query only if the error clearly indicates the query was malformed or too ambiguous; otherwise explain the failure briefly.

## Step 5: Verify playback

Prefer the script's own verification. Manual check: `osascript -e 'tell application "Music" to player position'` — the position must ADVANCE over time. Never trust `player state` alone: Music can report "playing" while no real track is loaded. Never verify with screenshots.

## Direct AppleScript (transport / volume / now playing)

- Pause: `osascript -e 'tell application "Music" to pause'` · resume: `… to play` · toggle: `… to playpause`
- Next: `… to next track` · previous: `… to previous track`
- Volume: `… to set sound volume to 60`
- Now playing: `… to (get name of current track) & " — " & (get artist of current track)`
- Library-only play: `… to play (item 1 of (search library playlist 1 for "Coldplay"))`

AppleScript library search only sees music the user owns — it cannot search or play the streaming catalog. If a library search comes back empty, do not keep scripting; run the validated script. Avoid hand-building shell commands around titles with apostrophes or quotes — the script takes raw titles safely.

## UI fallback in Music

Music's catalog UI is mostly NOT in the Accessibility tree: search-result tiles and album track rows don't appear in `ax.observe`, and `ax.click` fails there with "cannot be clicked" — do not retry AX clicks on catalog rows. Use `vision.capture` + `vision.click` instead, and only after the script's hint says the right page is on screen: capture → click the best visible song row or play button → verify player position advances → report. Perform one visual-click fallback only, unless the first click clearly selected the wrong element.

## Ambiguity

Pick the best likely match for ordinary ambiguity: "play hello" / "play baby don't cry" → the most popular likely match; "play drake" → owned Drake music or a popular catalog result; "play 80s music" → a popular 80s playlist/station. Ask only when the user explicitly wants to choose between versions, when interpretations are equally likely AND very different, or when the request isn't actually about music. Keep it short: "Which one did you mean: Adele, Lionel Richie, or another artist?"

## Failure behavior

Never fail silently; never say playback started unless it was verified; never retry the same query repeatedly; never open a web player; never claim catalog playback is possible through direct AppleScript. State the likely reason plainly: Apple Music streaming not active on this Mac, item unavailable, Music exposed no clickable result, the query couldn't be resolved, or no library match and catalog playback failed. Example: "I found the result in Music, but playback did not start. This usually means Apple Music streaming is not active on this Mac or the item is unavailable."

## Response style

Success: "Playing **{title}** by **{artist}**." Album: "Playing **{album}** by **{artist}**." Playlist/station: "Playing **{playlist/station}**." Transport/volume: "Paused." / "Resumed." / "Volume set to 60%." Keep responses short — the action matters more than the explanation.
