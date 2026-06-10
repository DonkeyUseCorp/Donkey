set mediaQuery to {query}
set trimmedQuery to mediaQuery as text

if trimmedQuery is "" then
    return "status=not_found" & linefeed & "clarification.required=true" & linefeed & "clarification.question=What would you like me to play?"
end if

tell application id "com.apple.Music"
    activate
    -- Prefer the Music dictionary directly (Automation only, no UI keystrokes) so playback of music
    -- the user OWNS is reliable and does not depend on Accessibility. `search` matches the query
    -- across title/artist/album. This only covers the local library, so if it finds nothing we fall
    -- back to the full-app search below, which reaches the Apple Music streaming catalog.
    set matches to (search library playlist 1 for trimmedQuery)
    if (count of matches) is not 0 then
        set chosen to item 1 of matches
        play chosen
        delay 0.6
        return "status=played" & linefeed & "source=local_library" & linefeed & "query=" & trimmedQuery & linefeed & "playedTitle=" & (name of chosen) & linefeed & "playedArtist=" & (artist of chosen)
    end if
end tell

-- Streaming fallback: the dictionary `search` only sees the local library, so for tracks the user
-- does not own we drive the Music app's own search field, which surfaces Apple Music streaming
-- results. The first Return submits the search; the second activates the top playable result.
delay 0.3

tell application "System Events"
    if not (exists process "Music") then
        return "status=failed" & linefeed & "failureReason=music_process_unavailable"
    end if

    tell process "Music"
        set frontmost to true
    end tell

    keystroke "f" using command down
    delay 0.2
    keystroke trimmedQuery
    delay 0.2
    key code 36
    delay 1.0
    key code 36
end tell

-- Verify something actually started playing before claiming success; the keystroke path can't tell
-- on its own whether a result was selected, so check the Music app's real player state.
delay 0.8
tell application id "com.apple.Music"
    if player state is playing then
        set playedTitle to trimmedQuery
        set playedArtist to ""
        try
            set playedTitle to name of current track
            set playedArtist to artist of current track
        end try
        return "status=played" & linefeed & "source=streaming" & linefeed & "query=" & trimmedQuery & linefeed & "playedTitle=" & playedTitle & linefeed & "playedArtist=" & playedArtist
    end if
end tell

return "status=not_found" & linefeed & "query=" & trimmedQuery & linefeed & "clarification.required=true" & linefeed & "clarification.question=I couldn't find " & trimmedQuery & " to play. What would you like me to play?"
