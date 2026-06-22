# Conversation Record

Every session writes a running record of itself to `conversation.md` — the real conversation plus the full reasoning and tool trace, one folder per conversation under Application Support (`Conversations/<id>/conversation.md`). It is human-readable markdown, appended live, so you can `tail -f` a run as it unfolds, and it is what the in-app conversation view renders back to the user. A compacted `summary.md` sits beside it; how that summary is built and how each model turn gets a bounded slice of this record is covered in [Context Compaction](context-compaction.md).

**The one rule:** every session event a user (or a maintainer reading the run) would want to see goes into the record, through the one transcript writer — never a bare `print`, never a log line that lives only in the console, never state that exists only in memory. If an event matters enough to happen, it matters enough to be in the record.

## How It Works

The conversation file is opened once per conversation and only ever appended to:

```text
begin                            (writes the header once; no-op if the file exists)
  -> userMessage / planning      (the turn opens)
  -> step / model call           (each executed step, each model call)
  -> system event / error        (lifecycle events; failures outside a tool result)
  -> response                    (the assistant's answer closes the turn)
  -> summary                     (regenerates the compacted summary.md)
```

The run loop records itself: the turn-trace manager is the single sink every model call and every executed step report to, so steps and model calls reach the record without callers thinking about it. Events that happen *outside* a run — pausing, resuming, approving, or denying from the notch — are recorded by the overlay model's lifecycle announcer, which writes the same line to the in-app event store and to the conversation file. **The run loop records the work; the lifecycle announcer records the user's controls.**

## Entry Kinds

Pick the kind that matches what happened; each renders with its own heading and icon.

| Kind | Use it for |
|---|---|
| user message | a request that opens a turn |
| planning | the parsed understanding that anchors a turn: goal, target app, parameters, success criteria, clarification |
| step | one executed step as a single block — the decision (thought, reason, action and its input), then that action's output |
| model call | one call to the model: clipped prompt and reply, finish reason, attempt, duration |
| response | the assistant's answer that closes a turn |
| system event | a lifecycle event — understanding parsed, run finished, agent paused, permission granted |
| error | something hit outside a tool result — a planner reply that couldn't be used, a run that aborted before starting |

The step is the only grouped block; everything else is a flat entry. Don't re-narrate a step as a separate system event — the step block already carries its decision and output.

## Rules

1. **One writer, append-only.** Open the record once and append. The header is written a single time; later turns and events only add to the end. Never truncate or rewrite the file.
2. **Keyed by conversation id.** Each conversation owns its folder, addressed by conversation id, so events from one conversation never bleed into another. Events carry the id of the agent that produced them, so a conversation's main agent and any subagents stay distinguishable within the one record.
3. **Typed activity, not raw strings.** Lifecycle lines come from the centralized activity vocabulary — one icon and label per kind — so the record stays consistent and the conversation view can render it. Don't invent a one-off status string like "Approved — continuing."
4. **Plain text in the store, markdown in the record.** The in-app event store keeps plain text — structured data the conversation view reads. The record keeps the icon-prefixed markdown line. Presentation stays out of the data store.
5. **Bounded and off the main thread.** Clip long prompts, replies, and outputs so a verbose run can't bloat the file, and write off the main thread — recording must never block the UI.

## Where It Lives

The transcript writer lives in the runtime; lifecycle events route through the overlay model's announcer, and the typed lines come from the shared activity vocabulary in the contracts. Start with the transcript writer.
