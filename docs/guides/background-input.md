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

```text
understand the turn ──► preference: background (default) or foreground
        │
   per action:
        ▼
   guard: is background safe for this target?       ┌─ no ─► foreground: raise the
     • the turn asked for background                │        app (one recovery), act
     • the window is a safe surface                 │        through the real cursor
     • it is on-screen (so on the active Space)      │
        │ yes                                        │
        ▼                                            │
   deliver to the target, no raise, no cursor move ◄─┘  (foreground is always available)
     • Accessibility action — for a control that advertises one
     • event to the process — for clicks, scroll, drag, keystrokes
```

The understanding step decides *whether* to run in the background; the guard
decides *whether that is safe* for the resolved window; the delivery lane
decides *how* the action reaches the app. A reader who remembers only that
split makes correct decisions.

Because a target window is resolved from the on-screen window list, a resolved
target is already on the active desktop and not minimized — so the guard needs
no separate desktop check, and a window on another desktop simply isn't found.

## The Two Background Lanes

Both reach the target process directly, so neither moves the cursor nor changes
which app is in front.

| Lane | Used for | How it acts |
|---|---|---|
| Accessibility action | a control that advertises a native action (press, open, show-menu, pick, confirm, cancel) | a cross-process Accessibility call on the exact control the agent observed |
| Event to the process | coordinate clicks, scrolling, dragging, typing, key chords | a synthetic event delivered to the target process |

The Accessibility lane is preferred wherever it applies — it activates the
control regardless of where it sits on screen. The event lane covers everything
the Accessibility lane can't express, including web-page content and text
entry.

## Delivery Falls Back, Never Flags

Background event delivery tries the richest path first and degrades on its own.
There is no switch to turn it on; it is enabled by detecting whether the system
entry points it needs are present.

1. The SkyLight path — cursor-neutral delivery that carries the live-input
   signal and the key-authentication envelope some apps (Chromium, Electron)
   require — is used when those private system entry points resolve.
2. Otherwise the public per-process post, also cursor-neutral, carries the
   event.
3. If neither can deliver to the process — or the control isn't drivable in the
   background, or the surface is unsafe — the action falls back to the
   foreground path, bringing the app to the front so the work still completes.

The richer paths are private and version-fragile, so they are isolated to one
place and treated as best-effort: a missing entry point means the next path
runs, never a dropped action.

## Invariants

1. **Every input is guarded.** Foreground input requires the target frontmost,
   recovering focus once before denying. Background input requires a safe,
   on-screen target and a cursor-neutral delivery lane. A sensitive surface —
   login, password, payment, system — is never driven in the background; it
   degrades to foreground so the user sees it.
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
