# Notes Writing
id: notes-writing
description: Plan writing finished text into a supported notes or text editor app.
tags: notes, writing, text, local-app
tools: app.openOrFocus, app.observe, ui.newDocument, ui.setText, app.verifyCommand

Use this skill for writing into a notes or text-editor app when the requested content is meaningful enough to type safely.

Set `query` to the complete final text to type. Do not set `query` to a category label, a restatement of the request, or placeholder text from instructions. If the writing form is clear but details are sparse, compose a short finished piece that satisfies the requested form.

If the requested object is malformed or nonsensical, choose conversation and ask for a clearer payload instead of opening the app.

When planning generic `local_app_interaction`, use `goal=write requested text`, `inputEntity=query`, `controlID=editor`, and tools `app.openOrFocus`, `app.observe`, `ui.newDocument`, `ui.setText`, `app.verifyCommand`.
