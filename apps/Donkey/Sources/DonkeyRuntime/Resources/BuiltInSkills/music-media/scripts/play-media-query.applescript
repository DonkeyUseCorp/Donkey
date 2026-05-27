set donkeyQuery to {query}
tell application "Music"
    activate
    delay 0.1
    try
        set donkeyMatches to search library playlist 1 for donkeyQuery only songs
        if (count of donkeyMatches) > 0 then
            play item 1 of donkeyMatches
            return "played-library-track"
        end if
    end try
end tell
try
    tell application "System Events"
        tell process "Music"
            set frontmost to true
            keystroke "f" using command down
            delay 0.12
            keystroke donkeyQuery
            delay 0.12
            key code 36
            delay 0.25
            key code 36
        end tell
    end tell
    return "searched-ui-first-result"
on error donkeyFallbackError
    return "ui-search-error:" & donkeyFallbackError
end try
