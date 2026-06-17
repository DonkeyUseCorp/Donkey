# Permission Pre-Gate

Every macOS permission Donkey needs while a task is running is asked for in the notch first. The system's own permission dialog never appears on its own mid-task.

**The one rule:** Donkey never asks macOS for a permission it doesn't already hold until the user has approved it in the notch. A task that needs one stops and shows an Approve / Deny banner; only on Approve does the system dialog appear. The microphone is the lone exception — clicking the mic button is itself the approval, and macOS's dialog follows from there.

## How It Works

Two decisions stack. First the user decides whether Donkey may ask macOS at all; only then does macOS decide the actual grant.

### User grant flow (the notch)

```
a running task needs a system permission
        │
        ▼
   already granted?  ── yes ──►  the tool just runs   (this check never prompts)
        │ no
        ▼
   the task stops and the notch shows a banner:
     "Needs your approval to control <app>"     [ Approve ]   [ Deny ]
        │                                            │
     Approve                                       Deny
        │                                            │
        ▼                                            ▼
   ask macOS now (system grant flow)          the task pauses, still resumable
        │                                      resuming asks again
   granted? ── yes ──►  the task continues and the tool runs
        │ no
        ▼
   the task needs attention
```

The split: Donkey decides *whether to ask*, the user decides *whether to allow*, and macOS decides the actual grant.

### System grant flow (only after Approve)

```
the user approved
        │
        ▼
   Donkey asks macOS for the permission
        │
        ▼
   macOS shows its own dialog  →  user grants or denies
        │
   granted → the task continues       denied → the task waits / needs attention
```

## Permission Inventory

Each permission Donkey can need while working, and how it is kept behind the gate.

| Permission | When it's needed mid-task | How it's handled |
| --- | --- | --- |
| Controlling another app | running an app-automation step | Stops at the notch gate; the system is asked only after Approve |
| Window housekeeping | un-minimizing a window before a screenshot | Done only if already granted, otherwise skipped — never asked (the app is already in front) |
| Screen recording | capturing the screen to see it | Checked but never asked mid-task; granted during first-run setup |
| Accessibility | reading or driving an app's controls | Checked but never asked mid-task; granted during first-run setup |
| Microphone | turning on voice from the notch | The mic button is the approval; macOS's dialog follows |

## Invariants

1. **Checking never prompts.** Asking "do we have this?" never shows a dialog. The only prompts are the one after Approve and the first-run setup screen.
2. **Deny is resumable.** Denying stops the task into a paused state; resuming runs it again and brings the banner back.
3. **Failure is graceful.** A wrong check at worst costs one extra Approve, and never blocks the agent from working.
4. **Housekeeping never prompts.** Background niceties skip themselves when their permission isn't held; they never raise a dialog.

## Where It Lives

One service owns checking and requesting permissions. The gate is raised where the harness runs a tool, and Approve triggers the request from the task lifecycle. The Approve / Deny banner is the permission row in the expanded notch.
