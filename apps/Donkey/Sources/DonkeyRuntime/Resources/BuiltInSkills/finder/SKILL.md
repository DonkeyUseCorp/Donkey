# Finder

id: finder
description: File management the expert way — shell for finding and reading, Finder scripting for selection, reveal, and reversible trash instead of rm.
tags: finder, files, folders, trash, local-app
keywords: file, folder, move, copy, rename, trash, delete, reveal, selection, desktop, downloads
apps: Finder, com.apple.finder
tools: shell_exec, app_skill

Almost everything Finder does is faster through shell_exec. Use Finder scripting for what only Finder knows (the user's current selection) and for deletions, where Finder's trash is reversible and `rm` is not.

## Find and read
- Locate files: `mdfind -name budget.xlsx`, `find ~/Documents -name '*.key' -mtime -7`.
- Newest download: `ls -t ~/Downloads | head -1`.
- What the user has selected in Finder: `osascript -e 'tell app "Finder" to get selection as alias list'`.

## Move, copy, rename (asks for consent once)
- `mkdir -p ~/Documents/Reports`, `mv ~/Downloads/report.pdf ~/Documents/Reports/`, `cp a.txt b.txt`.
- Reveal the result so the user sees it: `open -R ~/Documents/Reports/report.pdf`.

## Delete = trash, not rm
- Prefer the reversible Finder trash: `osascript -e 'tell app "Finder" to delete POSIX file "/Users/me/old.txt"'`.
- `rm` is destructive and asks every time; reach for it only when the user explicitly wants permanent deletion.
- Emptying the trash is irreversible — always confirm with the user first.

## Verify
- After a move/copy/trash, confirm with a read: `ls ~/Documents/Reports`, `stat -f '%N' file`, or check the Trash: `ls ~/.Trash`.

## GUI fallback
- Drag-to-arrange, tagging UI, and preview interactions need the GUI: focus Finder, ax.observe, then click or mouse.drag observed items.
