# Notes

id: notes
description: Create, find, and read Apple Notes through AppleScript — the destination step of most capture workflows — without driving the Notes GUI.
tags: notes, writing, text, capture, local-app
keywords: note, notes, save, write, jot, capture, checklist, remember
apps: Notes, com.apple.Notes
tools: shell_exec, app_skill

Notes is fully scriptable; almost every "save … to Notes" step is one `osascript` line. Do not open the Notes GUI to create a note.

## Create a note
- `osascript -e 'tell app "Notes" to make new note with properties {name:"Title", body:"First line<br>Second line"}'`
- The body is HTML: use `<br>` for line breaks, `<b>…</b>` for bold, `<ul><li>…</li></ul>` for lists.
- Always give a concrete `name` — it is the note's title. Compose the full finished body yourself; never save placeholder text.
- Escape any double quotes inside the text for the AppleScript string literal.

## Long content (a tracklist, a list, lyrics, anything big)
- A note body that won't fit in one short command — "all the songs from an album", "each song with its lyrics", a long summary — must NOT be jammed into one `osascript` string; shell commands are length-limited and the escaping breaks.
- Instead, generate the content with the `llm.generate` tool and set `toFile=true`. It returns a `filePath` holding the full text. For knowledge content (an album's tracklist, lyrics), the prompt is e.g. `List every song on Taylor Swift's latest album, one per line` or `For each of these songs, write the title then its lyrics`.
- Then create the note FROM that file (the command stays short, so no length limit), turning newlines into `<br>` so Notes renders the lines:
  `osascript -e 'set f to (read POSIX file "/tmp/donkey-llm-XXX.txt" as «class utf8»)' -e 'set AppleScript'"'"'s text item delimiters to (ASCII character 10)' -e 'set parts to text items of f' -e 'set AppleScript'"'"'s text item delimiters to "<br>"' -e 'tell application "Notes" to make new note with properties {name:"Title", body:(parts as text)}'`
- This is the general pattern for any "note with a lot in it": llm.generate(toFile) → read the file into the body. Build it up rather than giving up because "the list is too long".

## Putting computed values (date, battery, system state) in a note
- Do this in two plain steps, not one fragile command. First READ each value with its own simple command (`date '+%Y-%m-%d'`, `pmset -g batt | grep -o '[0-9]*%' | head -1`, `df -h /`), look at the output, then create the note with those literal values pasted into the body.
- Do NOT nest command substitutions (`$( … )`) inside the osascript string — the parentheses and quoting are error-prone and the parens also trip the safety classifier. Read first, then write the finished literal body.
- Example: after `date '+%Y-%m-%d'` returns `2026-06-10` and the battery read returns `100%`, run `osascript -e 'tell app "Notes" to make new note with properties {name:"Status", body:"Date: 2026-06-10<br>Battery: 100%"}'`.

## Find and read notes
- Titles of recent notes: `osascript -e 'tell app "Notes" to get name of notes 1 thru 5'`.
- Find by title: `osascript -e 'tell app "Notes" to get body of (note 1 whose name contains "Grocery")'` (body returns HTML).
- Newest note: `osascript -e 'tell app "Notes" to get name of note 1'` (notes list is most-recent first).

## Append to an existing note
- `osascript -e 'tell app "Notes" to set body of (note 1 whose name contains "Grocery") to (body of (note 1 whose name contains "Grocery")) & "<br>- milk"'`

## Show the result
- After creating, reveal it so the user sees it: `osascript -e 'tell app "Notes" to show note 1'` (opens Notes on that note).

## Verify
- Re-read the created note's name/body and confirm the content landed before completing.

## GUI fallback
- Locked notes, drawings, and attachments inside notes need the GUI: focus Notes, ax.observe, and drive the visible list and editor.
