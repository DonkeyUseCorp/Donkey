# Calendar

id: calendar
description: Read and create Calendar events through AppleScript with bounded date windows; deleting or moving events asks first.
tags: calendar, events, schedule, local-app
keywords: calendar, event, meeting, appointment, schedule, today, tomorrow, remind, invite
apps: Calendar, com.apple.iCal
tools: shell_exec, app_skill

Calendar is scriptable. Always bound queries to a named calendar and a date window — unbounded `every event` queries crawl years of history and time out.

## Read events
- List calendars first: `osascript -e 'tell app "Calendar" to get name of every calendar'`.
- Today's events in one calendar:
  `osascript -e 'tell app "Calendar" to tell calendar "Home" to get summary of (every event whose start date ≥ (current date) - (time of (current date)) and start date < (current date) - (time of (current date)) + 1 * days)'`.
- Keep windows to a day or a week; never query all calendars at once.

## Create an event (reversible; runs after one consent)
- `osascript -e 'tell app "Calendar" to tell calendar "Home" to make new event with properties {summary:"Dentist", start date:date "2026-06-12 14:00", end date:date "2026-06-12 15:00"}'`
- Use the calendar the user names; otherwise pick their primary writable calendar and say which one you used.
- Date literals depend on system locale; when a date fails to parse, build it in pieces: `set d to current date` then set its year/month/day/time properties before `make new event`.

## Delete or move events
- Destructive for the user's schedule — confirm the exact event (summary + start date) with the user before deleting or rescheduling.

## Verify
- Re-read the day's events after creating and confirm the new summary appears before completing.

## GUI fallback
- Invitee responses, travel time, and complex recurrence are easier in the GUI: focus Calendar, ax.observe, and drive the event editor.
