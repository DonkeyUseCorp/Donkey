# Numbers

id: numbers
description: Work with CSVs in the shell first; drive Numbers through AppleScript for opening, reading cells, and exporting PDFs.
tags: spreadsheet, table, numbers, csv, local-app
keywords: csv, spreadsheet, numbers, table, rows, columns, export, header, total
apps: Numbers, com.apple.iWork.Numbers
tools: shell_exec, app_skill

A CSV is a text file — read, filter, and summarize it with shell tools before reaching for Numbers. Open Numbers only when the user wants the document itself (viewing, editing, exporting).

## CSV in the shell (no app needed)
- Header row: `head -1 ~/Downloads/data.csv`. First rows: `head -5 data.csv`.
- Rows matching a term: `grep -i invoice data.csv`.
- A column (e.g. 3rd): `awk -F, '{print $3}' data.csv | head`.
- Newest CSV in Downloads: `ls -t ~/Downloads/*.csv | head -1`.

## Open in Numbers
- `open -a Numbers ~/Downloads/data.csv` — Numbers imports the CSV into a new document. `wait` ~2s for the import before observing or scripting.

## Read and edit cells via AppleScript
- Read a cell: `osascript -e 'tell app "Numbers" to get value of cell "B2" of table 1 of sheet 1 of front document'`.
- Set a cell: `… to set value of cell "B2" of table 1 of sheet 1 of front document to "42"'`.
- Row/column counts: `get row count of table 1 of sheet 1 of front document`.

## Export as PDF
- `osascript -e 'tell app "Numbers" to export front document to file ((path to desktop folder as text) & "data.pdf") as PDF'`
- Verify the file exists afterwards: `ls -t ~/Desktop | head -3`.

## Sorting and complex layout
- Sorting rows and visual table work are GUI tasks: focus Numbers, ax.observe, and click the column header or use the Organize sidebar. For pure data questions, prefer `sort -t, -k<col>` on the CSV instead.

## Verify
- Shell answers verify themselves (the output IS the evidence). Numbers edits: re-read the cell. Exports: `ls` the target file.
