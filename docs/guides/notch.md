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

Tasks run in parallel — several can be working at once — and the collapsed notch narrates them one update at a time. A new request that continues a task already running is folded into that task instead of starting another; an unrelated request starts a new task that runs alongside.

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

A task is always in one of three states, and the available controls follow from the state.

| State | Pointer | Controls | Clock |
| --- | --- | --- | --- |
| Running | Colored | Stop | Ticking |
| Stopped | Silhouette | Resume, Close | Frozen |
| Done | Silhouette | Close | Frozen |

**Stop is a pause.** Stopping freezes the clock and keeps the task in the list; resume returns it to running. Close removes the task. A done task can't resume the old run, but it can be picked back up — tapping the row continues the thread with a new message.

**Replying to a thread.** A thread is repliable whenever the user can pick it back up: one the agent is waiting on (a clarification or review — the white attention glyph), a finished one they want to continue, or a failed one they want to retry. **Tapping the row activates it** — that's the primary gesture, and it works for every repliable kind, including the ones the agent is asking about. A dedicated **Reply** button also appears, but only on the waiting kinds, since only there is the agent actively asking; it does the same thing as tapping the row. A waiting row's pointer gently pulses in the list — just enough to draw the eye to the thread that needs an answer. Activating a thread focuses the composer so the user can type straight away (no second click on the input) and pins the next message to that thread instead of running it through the follow-up classifier.

While a reply is targeted the panel makes the chosen thread the clear focus: every other row recedes to 50% opacity, and the composer is outlined in the targeted task's accent color so the input visibly belongs to that thread. The targeted row's pointer lights up in its original color even if the thread had finished or failed (its silhouette goes active again), and any other row still waiting on the user keeps its pointer lit while it dims, so no attention-needing thread disappears. Reply mode is a convenience, not a mode you're trapped in: tapping the active row again, tapping a non-repliable row, tapping bare notch chrome, or closing the task all leave it — and tapping a different repliable row just moves the focus there. Once dismissed, the next message goes back through the classifier, which may still land on the same thread or a different one.

**Stopped covers more than a pause.** A task also lands here when it runs long enough to hit its step ceiling (it reads as *timed out*) or when the app quits mid-run. All of these keep the task and its progress, so Resume picks the work back up — resuming re-runs the original goal with the work so far carried forward, not from scratch.

**Relaunch.** Reopening the app does not strand in-progress work. A task that was actively running moments before the app closed resumes on its own in the background. One that was interrupted longer ago or timed out comes back as a stopped row you resume with a tap. One that was still waiting on you comes back in that same state: a clarification or review keeps its Reply button and its question, and a permission gate keeps its Approve / Deny — answering or approving continues the task with its context intact. Pausing is a deliberate action you take on a running task, so a relaunch never recasts a waiting task as paused.

## Notifications

The collapsed right gutter shows exactly one thing, chosen by the rules below — never more. Most task states put nothing there at all; the gutter only lights up when the user actually needs to act, a task fails, or a task is running (the clock). A finished or merely-interrupted task is silent here — it keeps surfacing as its colored pointer and chin line, not as a gutter glyph.

Three glyphs exist, plus the running clock. Two of them share the same chat-bubble-with-warning-mark shape, separated by color — **white when the agent is waiting on the user, red when a task has failed.** Read them as: white asks you to do something, red tells you something broke.

| Glyph | Color | Means | Raised by |
| --- | --- | --- | --- |
| Chat bubble + warning | White | Attention — the agent is blocked waiting on the user | A task waiting for clarification or for review |
| Chat bubble + warning | Red | Error — a task failed and hasn't been acknowledged | A failed task still surfaced (cleared once the user expands the notch) |
| Shield | White | A required permission is missing | A task waiting for permission |
| Cloud + sync arrows | White | An app update is available, checked at launch | The updater, when nothing task-level is showing |
| Clock | — | A task is actively running | The running task's elapsed time |

**Collapsed gutter priority.** An unacknowledged failure (red) wins over everything, so a break is never hidden behind a clock. Otherwise the gutter follows the front task's state — attention, a permission shield, or the clock while it runs — and falls back to the update cloud only when no task needs the slot. A task that is done, paused, interrupted, timed out, or in a benign needs-attention state (an interrupted run restored across launches, an upload) raises nothing: it isn't waiting on the user, so it stays out of the gutter and surfaces only in the expanded list.

**Expanded.** Attention and error are read from the rows themselves once the notch is open, so they leave the gutter. A task that raised the white attention glyph carries a **Reply** control in its row — tapping it focuses the composer and pins the next message to that task, so the user's answer continues it rather than starting a new task. Only the app-level actions remain in the right-gutter action button, where permissions outranks update: Missing Permissions → Review, then Update Available → Restart.

## Logged Out

When the session signs out after a prior sign-in, the notch becomes a login
call-to-action rather than the task surface. Collapsed, it simply reads
"Login to use Donkey"; expanding reveals a wide, short bar with that label and
a Login button on the right. The button starts the normal Google sign-in, and
the surface returns to the task list once signed in. The stored session is
checked on launch, so an already-expired session shows login immediately
instead of waiting for the first request to fail. A brand-new install still
signs in through the welcome window, not the notch.

## Where It Lives

The behavior is realized today in the `/prototype` route under `site/`, in small per-piece components with shared task data and shapes in one tasks module and one types module. Bringing it to the Mac app is the next step; that work follows `docs/guides/swift-mvc.md` for view structure and keeps the notch a narrating surface per `docs/guides/user-query-overlay.md`.
