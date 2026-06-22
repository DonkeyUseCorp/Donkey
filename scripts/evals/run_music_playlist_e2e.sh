#!/usr/bin/env bash
set -euo pipefail

# Live end-to-end check of the music-playlist flow: submit
# "Create a playlist of the 10 best songs from 2000" to Donkey Dev as a real user turn —
# real hosted planning, real MusicKit, real Apple Music library — wait for the run to finish,
# then verify the outcome independently:
#   1. the turn's slice of thread.md shows the planning block and grouped step blocks and ends
#      with "Run finished: completed",
#   2. the Music app really has the created playlist with the expected tracks (read via
#      AppleScript, never trusted from the agent's own claims).
#
# A follow-up turn APPENDS to an existing thread.md (the app reuses the conversation thread), so
# every check runs against the content appended after submission, never the whole file.
#
# Requirements: persisted Donkey Dev login, an Apple Music subscription, the site dev server on
# :3000 (or DONKEY_WEB_BASE_URL pointing elsewhere), and Accessibility permission for the
# terminal running this script (System Events keystrokes drive the prompt).
#
# This CREATES A REAL PLAYLIST and Apple provides no delete API — remove it by hand in the
# Music app afterwards (the output names it).
#
# Usage: scripts/evals/run_music_playlist_e2e.sh
#   DONKEY_E2E_TIMEOUT    seconds to wait for the run to finish (default 600)
#   DONKEY_E2E_MIN_TRACKS minimum tracks for a pass (default 8 — the model may miss a search)

# BSD grep under a C locale silently fails to match multibyte patterns, so pin UTF-8 and keep all
# grep patterns ASCII-only anyway (the thread headings contain emoji and "·").
export LC_ALL=en_US.UTF-8

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMMAND_TEXT="Create a playlist of the 10 best songs from 2000"
THREADS_DIR="$HOME/Library/Application Support/Donkey/Threads"
TIMEOUT_SECONDS="${DONKEY_E2E_TIMEOUT:-600}"
MIN_TRACKS="${DONKEY_E2E_MIN_TRACKS:-8}"

THREAD_MD=""
BASE_LINES=0

# The turn's slice of the thread: everything appended after submission.
turn_text() {
  tail -n +"$((BASE_LINES + 1))" "$THREAD_MD"
}

fail() {
  echo "FAIL: $1" >&2
  if [ -n "$THREAD_MD" ] && [ -f "$THREAD_MD" ]; then
    echo "--- turn slice tail ($THREAD_MD from line $((BASE_LINES + 1))) ---" >&2
    turn_text | tail -n 40 >&2
  fi
  exit 1
}

# 1. Make sure Donkey Dev is running (build + launch when it is not).
if ! pgrep -xq "Donkey Dev"; then
  echo "Donkey Dev is not running — building and launching (this takes a few minutes)…"
  DONKEY_START_SITE=0 DONKEY_LAUNCH_APP=0 "$REPO_ROOT/scripts/run-donkey-dev.sh"
  DEV_APP_BINARY="$(find "$REPO_ROOT/apps/Donkey/.build" -path "*/debug/Donkey Dev.app/Contents/MacOS/Donkey Dev" | head -n 1)"
  [ -n "$DEV_APP_BINARY" ] || fail "built Donkey Dev binary not found under apps/Donkey/.build"
  "$DEV_APP_BINARY" > /tmp/donkey-music-e2e-stdout.log 2>&1 &
  for _ in $(seq 1 30); do
    pgrep -xq "Donkey Dev" && break
    sleep 1
  done
  pgrep -xq "Donkey Dev" || fail "Donkey Dev did not start"
  sleep 5 # let the overlay finish coming up
fi
echo "Donkey Dev is running."

# 2. Snapshot every existing thread.md's length, so the new turn is found by what got APPENDED.
SNAPSHOT="$(mktemp)"
trap 'rm -f "$SNAPSHOT"' EXIT
for md in "$THREADS_DIR"/*/thread.md; do
  [ -f "$md" ] || continue
  printf '%s %s\n' "$(wc -l < "$md" | tr -d ' ')" "$md"
done > "$SNAPSHOT"

# 3. Submit the command: double-tap Command opens the centered prompt focused, then type + return.
osascript <<'OSA'
tell application "System Events"
  key down command
  key up command
  delay 0.12
  key down command
  key up command
end tell
OSA
sleep 1.2
osascript -e 'on run argv' -e 'tell application "System Events" to keystroke (item 1 of argv)' -e 'end run' "$COMMAND_TEXT"
sleep 0.4
osascript -e 'tell application "System Events" to key code 36'
echo "Submitted: $COMMAND_TEXT"

# 4. Find the thread this turn landed in: new file, or existing file whose appended slice carries
#    the command.
for _ in $(seq 1 30); do
  while IFS= read -r dir; do
    md="$THREADS_DIR/$dir/thread.md"
    [ -f "$md" ] || continue
    old="$(grep -F " $md" "$SNAPSHOT" | head -n 1 | awk '{print $1}')"
    old="${old:-0}"
    if tail -n +"$((old + 1))" "$md" | grep -F "$COMMAND_TEXT" >/dev/null; then
      THREAD_MD="$md"
      BASE_LINES="$old"
      break
    fi
  done < <(ls -t "$THREADS_DIR" | head -n 5)
  [ -n "$THREAD_MD" ] && break
  sleep 2
done
[ -n "$THREAD_MD" ] || fail "no thread.md picked up the command within 60s — did the prompt open?"
echo "Thread: $THREAD_MD (turn starts after line $BASE_LINES)"

# 5. Wait for THIS turn's run to finish (the transcript's lifecycle event is the signal).
elapsed=0
until turn_text | grep "Run finished:" >/dev/null; do
  sleep 5
  elapsed=$((elapsed + 5))
  [ "$elapsed" -lt "$TIMEOUT_SECONDS" ] || fail "run did not finish within ${TIMEOUT_SECONDS}s"
done
echo "Run finished after ~${elapsed}s."

# 6. Assert the turn reads as the grouped trace and the run completed. Step numbers continue
#    across turns on a reused thread, so match any step heading. The planning block depends on the
#    15s understanding deadline; the documented fallback line is the acceptable absence.
if turn_text | grep -E "^### .*assistant.*planning" >/dev/null; then
  echo "Planning block present."
elif turn_text | grep "Understanding was unavailable" >/dev/null; then
  echo "WARN: understanding timed out this turn — planning block legitimately absent."
else
  fail "turn has neither a planning block nor the understanding-unavailable event"
fi
turn_text | grep "^## Step " >/dev/null || fail "turn has no grouped step blocks"
# A completed run logs "Run finished: ok"; anything else (failedSafe, stuckRepeatingFailure…) fails.
turn_text | grep -E "Run finished: (ok|completed)" >/dev/null || fail "run did not complete: $(turn_text | grep 'Run finished:')"

# 7. Independent verification: read the created playlist straight from the Music app. The name
#    comes from the LAST create action recorded in the thread — a rerun on a reused thread may
#    fill a playlist created in an earlier turn, so the whole file is searched, not just the
#    slice. The track count comes from AppleScript. Cloud-created playlists can take a moment to
#    sync into the local library, so retry briefly.
PLAYLIST_NAME="$(awk '/^action: create$/{f=1; next} f && /^name: /{sub(/^name: /,""); last=$0; f=0} END{print last}' "$THREAD_MD")"
[ -n "$PLAYLIST_NAME" ] || fail "no music.playlist create action with a name found in the thread"
echo "Created playlist (per thread): $PLAYLIST_NAME"

# Cloud-created playlists and their tracks sync into the local library on their own schedule —
# observed taking several minutes. Poll generously, take the MAX track count across all playlists
# with the name (an older empty duplicate must not mask the filled one), and relaunch Music once a
# minute — it pulls the cloud library on launch, which reliably nudges a stalled sync.
SYNC_TIMEOUT="${DONKEY_E2E_SYNC_TIMEOUT:-360}"
TRACK_COUNT=""
sync_elapsed=0
while [ "$sync_elapsed" -lt "$SYNC_TIMEOUT" ]; do
  TRACK_COUNT="$(osascript \
    -e 'on run argv' \
    -e 'set best to -1' \
    -e 'tell application "Music"' \
    -e 'repeat with p in (every user playlist whose name is (item 1 of argv))' \
    -e 'set trackCount to (count of tracks of p)' \
    -e 'if trackCount > best then set best to trackCount' \
    -e 'end repeat' \
    -e 'end tell' \
    -e 'if best is -1 then return ""' \
    -e 'return best' \
    -e 'end run' "$PLAYLIST_NAME" 2>/dev/null || true)"
  if [ -n "$TRACK_COUNT" ] && [ "$TRACK_COUNT" -ge "$MIN_TRACKS" ]; then
    break
  fi
  echo "Waiting for library sync (playlist: ${TRACK_COUNT:-absent})…"
  sleep 10
  sync_elapsed=$((sync_elapsed + 10))
  if [ $((sync_elapsed % 60)) -eq 0 ]; then
    osascript -e 'tell application "Music" to quit' 2>/dev/null || true
    sleep 3
  fi
done
[ -n "$TRACK_COUNT" ] || fail "playlist \"$PLAYLIST_NAME\" never appeared in the Music app library"
[ "$TRACK_COUNT" -ge "$MIN_TRACKS" ] || fail "playlist \"$PLAYLIST_NAME\" has only $TRACK_COUNT track(s), expected >= $MIN_TRACKS"

echo "PASS: \"$PLAYLIST_NAME\" exists in Music with $TRACK_COUNT tracks."
echo "Thread: $THREAD_MD"
echo "Reminder: Apple has no playlist-delete API — remove \"$PLAYLIST_NAME\" in the Music app when done."
