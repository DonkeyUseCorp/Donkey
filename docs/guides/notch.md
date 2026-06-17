# Notch

The notch is Donkey's always-on surface at the top center of the screen. It works at two scales: a small bar you glance at, and a panel you open to see every task and type a new one. This guide is the anatomy and behavior contract for that surface. The working reference is the `/prototype` route in the site; the Mac app's notch should match what this describes.

**The one rule:** the collapsed bar shows one thing at a time; the expanded panel shows everything and lets you act. Collapsed is for glancing; expanded is for working. If a state needs more than a single line plus one status, it belongs in the expanded panel — never stack a list, a second notification, or controls into the collapsed bar.

This guide covers the notch surface only — its layout, the chin, the task list, and notifications. Grounded cursor playback and the centered voice prompt live in `docs/guides/user-query-overlay.md`; the one piece they share is that double-tapping Command opens the centered composer, which adds a task to this notch.

## How It Works

The notch is pinned top-center. Pointer hover expands it; moving away collapses it. Content never renders inside the physical notch void, and displays without a hardware notch use the same top-center composition without reserving space they don't have.

```
COLLAPSED (real notch — reference frame 253 × 32, 14px bottom corners)
   ┌─ left ──┐┌──── notch void ─────┐┌─ right ──┐
   │  ◤      ││   (hardware notch)   ││  12m 3s  │   ← notch row, 32px
   └─────────┘└──────────────────────┘└──────────┘
   │ Comparing the top options…                  │   ← chin, ~20px, only while streaming

EXPANDED (reference frame 604 × 312, 14px corners)
   ┌──────────────────────────── notch window ───────────────┐
   │  (notch row stays empty)            Update Available [↻] │  ← right-gutter action
   │  ◤  Compare options                              [■]     │
   │     Ranking the best options…                  12m 3s    │  ← scrollable task list
   │  ◤  Gather research …                                    │
   │  ┌────────────────────────────────────────────────────┐ │
   │  │ What can Donkey do for you?                    (↑)  │ │  ← input, always visible
   │  └────────────────────────────────────────────────────┘ │
   └──────────────────────────────────────────────────────────┘
```

The collapsed bar reflects live task activity. The expanded panel is the task list plus the input. Sizes above are the reference frames; the app derives them from layout metrics rather than hardcoding, but the row height, gutter width, and corner radius are the design values to hit.

## Notch Row: Gutters and Void

The collapsed notch is three zones across one row. The middle is the **void** — the physical notch, where nothing renders. The two zones flanking it are the **gutters**, each one icon wide (34px in the reference).

| Zone | Collapsed | Expanded |
| --- | --- | --- |
| Left gutter | The surfaced pointers: a colored arrow per active or just-finished task, gently pulsing while one streams. Several stack as a small overlapping cluster — up to three, the group centered — and a gray silhouette shows when nothing is surfaced. | Empty. |
| Void | The hardware notch. Always empty. | Empty. |
| Right gutter | One status only: the running clock, or a single notification icon. | One app-level action button (see Notifications). |

A display with no hardware notch uses a free-floating pill: no void, square top corners, rounded bottom, and the streaming message inline (two lines) instead of a separate chin.

## Chin

The chin is the strip that drops below the real notch while a task is streaming. It shows a single line of the current update in small text, with an ellipsis if it overflows. It exists only while something is streaming and only while collapsed; expanding hides it.

## Streaming and the Queue

Tasks form a queue, and the collapsed notch narrates that queue one update at a time.

1. **New tasks join the front.** Submitting from either input prepends a running task so it is visible first.
2. **Running tasks stream updates.** Every couple of seconds the chin advances to the next running task's latest update.
3. **The arrow color follows the speaker.** Whichever task produced the current chin line, the left arrow takes that task's color.
4. **A new task announces itself, then yields.** On add, the chin briefly shows the new task's own color and subtext, then the rotation resumes with the next update.
5. **Finished work lingers.** A completed task keeps its colored pointer, and its last line in the chin, on the collapsed bar after it stops — a result is never dropped the instant it lands. Several completions stack as the overlapping cluster.
6. **Expanding clears it.** Opening the notch dismisses those finished pointers: the tasks stay in the expanded list, but the collapsed bar stops surfacing them. Once nothing is surfaced the chin disappears and the arrow returns to a silhouette.

## Expanded Panel

The expanded panel is a scrollable list of task rows above an input that is pinned to the bottom and always visible. A row is a pointer, a title, a subtext, one control, and an elapsed time. The subtext wraps up to five lines and then truncates with an ellipsis. The elapsed time sits in a fixed spot beneath the control so it never shifts on hover, and the delete affordance only appears for idle tasks.

Two inputs add to the same queue: the centered composer summoned by double-tapping Command, and the input at the bottom of this panel. Both grow from one line as their text grows, keep the send button in the lower-right corner, and disable that button until there is text to send.

## Task States

A task is always in one of three states, and the available controls follow from the state. A running task finishes on its own after about three minutes.

| State | Pointer | Controls | Clock |
| --- | --- | --- | --- |
| Running | Colored | Stop | Ticking |
| Stopped | Silhouette | Resume, Close | Frozen |
| Done | Silhouette | Close | Frozen |

**Stop is a pause.** Stopping freezes the clock and keeps the task in the list; resume returns it to running. Close removes the task. A done task cannot resume — it can only be closed.

## Notifications

Three notification kinds surface on the notch, each tied to a condition. In the collapsed right gutter they share one slot by priority: attention first, then the running clock, then permissions, then update. When expanded they move to the right-gutter action, where permissions outranks update.

| Kind | Icon | Means | Expanded action |
| --- | --- | --- | --- |
| Attention | Chat bubble with a warning mark | The model needs the user — a clarification | — |
| Update | Cloud with sync arrows | An app update is available, checked at launch | Update Available → Restart |
| Permissions | Shield | A required permission is missing | Missing Permissions → Review |

## Where It Lives

The behavior is realized today in the `/prototype` route under `site/`, in small per-piece components with shared task data and shapes in one tasks module and one types module. Bringing it to the Mac app is the next step; that work follows `docs/guides/swift-mvc.md` for view structure and keeps the notch a narrating surface per `docs/guides/user-query-overlay.md`.
