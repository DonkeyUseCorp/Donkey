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
- For the USER's files, prefer the reversible Finder trash: `osascript -e 'tell app "Finder" to delete POSIX file "/Users/me/old.txt"'`. `rm` outside your own workspace is destructive and asks every time — reach for it only when the user explicitly wants permanent deletion.
- Inside the workspace folder you own, `rm` with the full workspace path (`rm "<workspace>/scratch.txt"`) runs without asking — including a clean-up chain of file commands like `mv "<workspace>/a" "<workspace>/b" && rm "<workspace>/a"`. A bare name, `*`, `$VAR`, or any non-file command in the chain still prompts.
- Emptying the trash is irreversible — always confirm with the user first.

## Creating and Naming Folders and Files
- When creating directories (folders) or files to organize documents, do NOT use the user's raw prompt or simply truncate the input.
- **Root Folders:**
  - Generate a very short, user-friendly, and descriptive folder name (2-4 words), ensuring you **correct any spelling mistakes** in the user's query (e.g., `"standard daviation chart"` -> `"Standard Deviation Chart"`).
  - Format the root folder name as a nice, natural sentence or title with space-separated words, using natural capitalization (e.g., `"Collapsing the Notch"`, `"Organize tax files"`).
  - Deterministically or creatively map the conversation ID or target to a super-friendly 3-4 letter word (such as `mint`, `wave`, `cozy`, `fern`, `pine`, `glen`, `vibe`, `snug`, `glow`, `plum`), and append it at the end of the root folder name as a capitalized unique hash word (e.g., `"Collapsing the Notch Cozy"`, `"Organize Tax Files Cozy"`).
- **Child Folders and Files:**
  - Any child folders and files created *inside* the root folder should be formatted in **CamelCase** (or **PascalCase** where each word is capitalized with no spaces), correcting any spelling mistakes (e.g., a folder name like `"tax receipts"` becomes `TaxReceipts`, and a file name like `"f1120 form.pdf"` becomes `F1120Form.pdf`).

## Verify
- After a move/copy/trash, confirm with a read: `ls ~/Documents/Reports`, `stat -f '%N' file`, or check the Trash: `ls ~/.Trash`.

## GUI fallback
- Drag-to-arrange, tagging UI, and preview interactions need the GUI: focus Finder, ax.observe, then click or mouse.drag observed items.
