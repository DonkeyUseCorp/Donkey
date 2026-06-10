# Documents

id: documents
description: Work with PDFs and images in Preview — which is NOT scriptable — using keyboard shortcuts and shell tools (sips, mdls) for the heavy lifting.
tags: preview, pdf, image, documents, local-app
keywords: pdf, preview, image, rotate, export, extract, text, page, scan, receipt, invoice, form
apps: Preview, com.apple.Preview
tools: shell_exec, app_skill

Preview has no useful AppleScript dictionary. Open files with `open`, do file-level work with shell tools, and use keyboard shortcuts for in-app actions. Expect a short `wait` after opening before the document is ready.

## Find the newest PDF or image
- Commands run under `zsh`, where a glob that matches nothing ABORTS the whole command (`no matches found`). To find the newest file of several types, list by time and filter with grep instead of globbing many extensions:
  - Newest image: `ls -t ~/Downloads | grep -iE '\.png$|\.jpg$|\.jpeg$|\.gif$|\.heic$|\.webp$|\.tiff$' | head -1`
  - Newest PDF: `ls -t ~/Downloads/*.pdf | head -1` (single extension is safe), or `ls -t ~/Downloads | grep -i '\.pdf$' | head -1`.
  - The result is a bare filename; prefix `~/Downloads/` when passing it on.
- Keep parentheses OUT of shell commands: the safety classifier treats `(`/`)` (subshells, `find \( \)`, glob qualifiers like `(N)`) as separate commands and prompts for approval even on a read-only command. The `ls … | grep -iE` form above is parenthesis-free and runs instantly.
- Never conclude "no images/files exist" from a `no matches found` error — that means the glob was too strict, not that the folder is empty. Retry with the `ls | grep` form.

## Open
- `open -a Preview ~/Downloads/file.pdf` (or just `open file.pdf` when Preview is the default). Then `wait` ~1s before acting.

## Read text out of a PDF without the GUI
- Spotlight has already extracted most PDFs' text: `mdls -name kMDItemTextContent ~/Downloads/receipt.pdf` returns the document text — search it for totals, invoice numbers, confirmation codes with `grep`.
- Title metadata: `mdls -name kMDItemTitle -name kMDItemDisplayName file.pdf`.
- When Spotlight has no text (unindexed or scanned image PDF), fall back to the GUI: focus Preview, select all and copy (`keyboard.press key=a modifiers=command`, then `key=c modifiers=command`), then read it with `pbpaste`.

## Image operations — prefer sips over the GUI
- Rotate the FILE directly: `sips -r 90 image.png` (90 = right/clockwise; use the GUI only if the user wants to see it happen: open in Preview, then Cmd+R rotates right, Cmd+L left).
- Resize/convert: `sips -Z 800 image.png`, `sips -s format pdf image.png --out image.pdf`.

## In-Preview actions (keyboard, after focusing Preview)
- Rotate right/left: Cmd+R / Cmd+L. Select all text: Cmd+A. Copy selection: Cmd+C (then `pbpaste` to read it).
- PDF form fields: press Tab to move to the first/next fillable field, then type with text.enter.
- Export/Save As has no shortcut: use ax.observe on the menu bar (File → Export as PDF…) and click the menu items.

## Verify
- File-level edits: re-read with `mdls`/`stat`/`sips -g pixelWidth -g pixelHeight`. Clipboard copies: `pbpaste | head`. GUI actions: re-observe Preview.
