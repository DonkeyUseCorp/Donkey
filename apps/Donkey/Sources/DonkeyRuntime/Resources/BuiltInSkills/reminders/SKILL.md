# Reminders

id: reminders
description: Create and read Apple Reminders through AppleScript — with due dates and alerts — without driving the Reminders GUI.
tags: reminders, tasks, todo, local-app
keywords: reminder, remind, task, todo, due, checklist, alert
apps: Reminders, com.apple.reminders
tools: shell_exec, app_skill

Reminders is fully scriptable; creating a reminder is one `osascript` line. Creating reminders is reversible — act directly.

## Create a reminder
- Simple: `osascript -e 'tell app "Reminders" to make new reminder with properties {name:"Call Alex"}'`
- With a due date/alert: build the date in pieces (locale-proof), then create:
  `osascript -e 'set d to current date' -e 'set hours of d to 9' -e 'set minutes of d to 0' -e 'set d to d + 1 * days' -e 'tell app "Reminders" to make new reminder with properties {name:"Call Alex", remind me date:d}'`
- Into a specific list: `tell app "Reminders" to tell list "Work" to make new reminder …`. List the lists first: `osascript -e 'tell app "Reminders" to get name of every list'`.
- Several reminders (e.g. a checklist from a note): one `make new reminder` per item; keep each item's text as the reminder name.

## Read reminders
- Incomplete reminders in a list: `osascript -e 'tell app "Reminders" to get name of (reminders of list "Work" whose completed is false)'`. Always bound by list and completion state — unbounded queries over all reminders are slow.

## Complete or delete
- Mark done is reversible: `set completed of reminder "Call Alex" of list "Work" to true`.
- Deleting a reminder asks the user first.

## Verify
- Re-read the list and confirm the new reminder's name (and date when set) before completing.
