set mediaQuery to {query}
set trimmedQuery to mediaQuery as text

if trimmedQuery is "" then
    return "status=not_found" & linefeed & "clarification.required=true" & linefeed & "clarification.question=What would you like me to play?"
end if

-- 1) Local library first: instant, Automation-only, and a broad term (artist, mood word) plays
-- whatever the user owns. `search` matches the query across title/artist/album.
tell application id "com.apple.Music"
    activate
    set matches to (search library playlist 1 for trimmedQuery)
    if (count of matches) is not 0 then
        set chosen to item 1 of matches
        play chosen
        delay 0.6
        return "status=played" & linefeed & "source=local_library" & linefeed & "query=" & trimmedQuery & linefeed & "playedTitle=" & (name of chosen) & linefeed & "playedArtist=" & (artist of chosen)
    end if
end tell

-- 2) Not owned: resolve the MOST POPULAR catalog match via the iTunes Search API — one curl,
-- no UI, popularity-ranked, and it gives back the exact track/album link. This replaces the
-- old type-into-the-search-field dance, which could surface results but never start playback.
set resolvedTitle to ""
set resolvedArtist to ""
set resolvedURL to ""
try
    -- limit=5, first result taken: asking the API for limit=1 invokes a different (worse)
    -- ranking tier, e.g. returning a cover instead of the popular original.
    set apiJSON to do shell script "curl -s -m 4 -G 'https://itunes.apple.com/search' --data-urlencode 'entity=song' --data-urlencode 'limit=5' --data-urlencode " & quoted form of ("term=" & trimmedQuery)
    set firstResult to do shell script "printf '%s' " & quoted form of apiJSON & " | awk -F'\"wrapperType\"' '{print $2}'"
    set resolvedTitle to do shell script "printf '%s' " & quoted form of firstResult & " | sed -nE 's/.*\"trackName\":\"([^\"]+)\".*/\\1/p' | head -1"
    set resolvedArtist to do shell script "printf '%s' " & quoted form of firstResult & " | sed -nE 's/.*\"artistName\":\"([^\"]+)\".*/\\1/p' | head -1"
    set resolvedURL to do shell script "printf '%s' " & quoted form of firstResult & " | sed -nE 's/.*\"trackViewUrl\":\"([^\"]+)\".*/\\1/p' | head -1"
end try

if resolvedURL does not start with "https://music.apple.com/" then set resolvedURL to ""

if resolvedURL is not "" then
    -- music:// routes the link into the Music app natively (https:// would not navigate it)
    -- and lands on the album page with the requested track highlighted.
    set deepLink to "music" & (text 6 thru -1 of resolvedURL)
    do shell script "open " & quoted form of deepLink
    delay 1.5
    tell application id "com.apple.Music"
        play
        -- Verify with the player position AND the track name, not `player state`: state can
        -- report "playing" while nothing is loaded (position pinned at 0, e.g. with no Apple
        -- Music subscription), and a bare `play` can resume a previously loaded track instead
        -- of the requested one.
        set verified to false
        repeat 5 times
            delay 0.7
            try
                if player state is playing and player position > 0.3 then
                    set nowName to ""
                    try
                        set nowName to name of current track
                    end try
                    if nowName is not "" and (nowName contains resolvedTitle or resolvedTitle contains nowName) then
                        set verified to true
                        exit repeat
                    end if
                end if
            end try
        end repeat
        if verified then
            set playedTitle to resolvedTitle
            set playedArtist to resolvedArtist
            try
                set playedTitle to name of current track
                set playedArtist to artist of current track
            end try
            return "status=played" & linefeed & "source=streaming" & linefeed & "query=" & trimmedQuery & linefeed & "playedTitle=" & playedTitle & linefeed & "playedArtist=" & playedArtist
        end if
    end tell
    -- The exact track's album page is on screen but playback would not start from script-level
    -- `play`. A real click on the song row (the vision agent) is the remaining move; if even that
    -- does not play, it's a Music account/subscription problem the user must fix — say so.
    return "status=not_found" & linefeed & "query=" & trimmedQuery & linefeed & "resolvedTitle=" & resolvedTitle & linefeed & "resolvedArtist=" & resolvedArtist & linefeed & "hint=The track's album page is open in Music but scripted playback did not start. Vision-click the song row to play it. If playback still does not start, ask the user to check Music's sign-in / Apple Music subscription — do not keep retrying." & linefeed & "escalate.app=Music" & linefeed & "escalate.goal=Double-click the song row " & resolvedTitle & " on the album page now on screen, then verify player position advances"
end if

-- 3) Nothing owned and the catalog lookup failed (offline or no API match): report honestly.
return "status=not_found" & linefeed & "query=" & trimmedQuery & linefeed & "hint=No local library match and the catalog lookup returned nothing. Ask the user or try a different query wording." & linefeed & "escalate.app=Music" & linefeed & "escalate.goal=Search Music for " & trimmedQuery & " and play the top song result"
