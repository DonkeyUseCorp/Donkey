# Spreadsheet Tables
id: spreadsheet-tables
description: Plan creating compact tables in a supported spreadsheet app.
tags: spreadsheet, table, numbers, local-app
tools: app.openOrFocus, app.observe, ui.newDocument, ui.setText, app.verifyCommand

Use this skill for simple table or spreadsheet creation when a supported spreadsheet app is available.

Set `query` to compact tab-separated table content, including a header row. If exact live data is unavailable, make a table-shaped brief with a data-needed note instead of a single sentence.

When a table request needs fresh data from another local app before creating the final spreadsheet, keep the final destination app as `targetAppName` and record the source-to-destination sequence in `metadata.appChain` as a JSON string array of app names.

When planning generic `local_app_interaction`, use `goal=create requested table`, `inputEntity=query`, `controlID=editor`, and tools `app.openOrFocus`, `app.observe`, `ui.newDocument`, `ui.setText`, `app.verifyCommand`.
