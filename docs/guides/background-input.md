# Background Input

Donkey runs the user's work in the background by default: it drives a target
app — clicking, typing, scrolling — without taking over the real cursor or
pulling the app to the front. The user keeps working in whatever they are
focused on while the agent acts on another window. Foreground driving, where
the agent visibly takes over the screen, is the exception, reserved for turns
whose whole point is for the user to watch (pulling something up, a
walkthrough, "how do I…").

**The one rule:** whether a turn runs in the background or the foreground is a
typed decision made once by the request-understanding step, never inferred from
the user's words. Deterministic code reads that one field; it never inspects
the raw request. If you're tempted to check whether a command "sounds like" a
show-me request, that classification belongs in the understanding step, which
returns a typed preference the rest of the system obeys.

## How It Works

Every turn carries a typed preference — background by default. Per action, a
guard decides whether background delivery is safe for the resolved window; a
foreground turn, or a sensitive surface like a login or payment, degrades to the
foreground path. Because a target is resolved from the on-screen window list, it
is already on the active desktop and not minimized — no separate desktop check,
and a window on another desktop simply isn't found.

The truth macOS imposes on the rest: a synthetic mouse or scroll event only
lands on the **active** app. A window that isn't in front silently drops it,
however the event is routed to the process. So "background" is not one trick — it
is a ladder, and which rung an action takes depends on what the app exposes.
None of this is app-specific: the rungs are chosen from what a window advertises,
never from which app it is.

## Reading Is Always Background

Seeing never needs the foreground. The agent reads a window two ways, both of
which work while it sits in the background and neither of which moves the cursor
or raises the app:

- **Accessibility text** — fast and structured, for content that lives in the
  Accessibility tree.
- **Screenshot + on-device OCR** — for content an app draws itself and does not
  put in the Accessibility tree at all (a chat transcript's bubbles, a canvas, a
  custom list). The window's pixels are captured without raising it and the text
  is recognized on device.

A single read tool gathers content that runs past one screen — a chat backlog, a
long feed — by scrolling and re-reading in one call, so a scrollback that would
otherwise be dozens of look-scroll-look steps costs one.

## Acting In The Background

Acting takes the richest rung that reaches the app without the foreground:

1. **Accessibility action** — press, open, show-menu, and *scroll by page* are
   cross-process Accessibility calls that act on a window regardless of whether
   it is frontmost. This is the preferred rung: a control that advertises an
   action, and a scroll view that advertises page scrolling, are both driven with
   no raise and no cursor. Most native lists expose a page-scrollable area even
   when their rows are drawn outside the Accessibility tree — so a custom-drawn
   transcript still scrolls in the background.
2. **Synthetic event to the process** — a cursor-neutral event posted to the
   target process, carrying the live-input signal and the key-authentication
   envelope some apps (Chromium, Electron) require. This reaches apps that accept
   routed input — chiefly keyboard and text entry — but a window that isn't active
   drops synthetic mouse and scroll, so it is not a reliable background path for
   coordinate gestures on every app.
3. **Brief foreground, then restore** — when a gesture can only land on the active
   app (a coordinate click on a control with no Accessibility action, a scroll an
   app ignores while backgrounded), the agent brings the target to the front for
   the moment of the gesture, acts through the real event tap, and hands focus
   back to whatever the user had in front. Reading around the gesture stays in the
   background; only the gesture itself borrows focus.

The upshot: reading and scrolling a typical native app — including one whose
content is custom-drawn — stay fully in the background. Only a click on something
the app exposes no Accessibility action for has to borrow the foreground, and even
then it returns focus immediately.

## Invariants

1. **Every input is guarded.** Foreground input requires the target frontmost,
   recovering focus once before denying. Background input requires a safe,
   on-screen target. A gesture that can only land on the active app borrows the
   foreground for the moment of the action and restores the user's app after. A
   sensitive surface — login, password, payment, system — is driven in the
   foreground so the user sees it.
2. **Done means evidence.** A background action runs where the user isn't
   looking, so the agent re-observes and confirms the effect. A completion whose
   last state-changing action has no later succeeded verification is rejected.
3. **The overlay stays cosmetic.** Background turns suppress the traveling
   cursor and narrate progress through the notch text alone; the overlay never
   delivers real input, and no real pointer moves.

## Where It Lives

The guard and the input lanes — Accessibility actions and the process-delivery
path — live in the runtime layer that owns guarded execution; the typed
background preference is set in the request-understanding step and threaded into
the act tools.
