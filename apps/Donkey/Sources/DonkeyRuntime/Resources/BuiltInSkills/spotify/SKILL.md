# Spotify

id: spotify-operate
description: Operate the Spotify desktop app by vision to search for and play music.
tags: media, music, playback, spotify, electron, vision
keywords: spotify, play, listen, music, song, track, album, playlist, artist, band
apps: Spotify, com.spotify.client

Spotify is an Electron app, so accessibility and AppleScript expose almost no useful controls — drive it by VISION (look at the screenshot and click). This skill is the operating playbook the per-turn vision driver follows; it describes WHERE things are conceptually, never fixed pixel coordinates (the window can be any size — always read the current screenshot).

## Layout you will see

- Top center: a search field with placeholder text like "What do you want to play?". Click it to focus, then type.
- Left: "Your Library" sidebar with recent items.
- Main area: the current page (artist page, search results, etc.). An artist page shows the artist name, a large round green Play button, and a "Popular" list of songs numbered 1, 2, 3…
- Bottom: the persistent PLAYBACK BAR spanning the whole window. Its center holds the transport controls: shuffle, previous, the round PLAY/PAUSE button, next, repeat. The currently loaded track (name + artist) shows at the far bottom-left, with a progress time like "0:05 / 4:26".

## How to play an artist's music

1. Click the top search field, then `type` the artist or song name, then `key` "return" to submit.
2. On the results/artist page, click the artist (or the specific song row) to open it.
3. Start playback. The most reliable control is the round PLAY button in the bottom playback bar (it is centered HORIZONTALLY in the window and centered VERTICALLY within the bar — it is NOT at the very bottom edge of the window; aim for the middle of the bar, not its bottom pixel row). The large green button on an artist page also works and plays the artist's top song.

## Reading playback state (critical — do not toggle music off)

The bottom transport button is a PLAY/PAUSE toggle, so its icon tells you the current state:

- ▶ TRIANGLE icon = PAUSED/STOPPED. The progress time is frozen (e.g. stuck at 0:05). Music is NOT playing — click it to start.
- ⏸ TWO VERTICAL BARS icon = PLAYING right now. Also, a small green animated equalizer bars icon appears next to the playing track. Only when you see ⏸ (or the track time is advancing) is the goal met — stop and report done.

Never click the transport button while it shows ⏸; that pauses the music. Only emit "done" once the screenshot shows the ⏸ icon or a clearly advancing track time.

## If a click does not change anything

If you clicked a control and the next screenshot looks identical (same ▶ icon, same frozen time), your click MISSED the target — do not repeat the exact same coordinate. Re-locate the button in the new screenshot and aim for its precise visual center; for the bottom transport button, move your aim UP into the middle of the playback bar rather than toward the window's bottom edge.
