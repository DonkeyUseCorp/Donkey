set mediaQuery to {query}
set trimmedQuery to mediaQuery as text

if trimmedQuery is "" then
    return "status=not_found" & linefeed & "clarification.required=true" & linefeed & "clarification.question=What would you like me to play?"
end if

tell application id "com.apple.Music"
    activate
    -- Use the Music dictionary directly (Automation only, no UI keystrokes) so playback is reliable
    -- and does not depend on Accessibility. `search` matches the query across title/artist/album.
    set matches to (search library playlist 1 for trimmedQuery)
    if (count of matches) is 0 then
        return "status=not_found" & linefeed & "query=" & trimmedQuery & linefeed & "clarification.required=true" & linefeed & "clarification.question=I couldn't find " & trimmedQuery & " in the library. What would you like me to play?"
    end if

    set chosen to item 1 of matches
    play chosen
    delay 0.6
    return "status=played" & linefeed & "query=" & trimmedQuery & linefeed & "playedTitle=" & (name of chosen) & linefeed & "playedArtist=" & (artist of chosen)
end tell
