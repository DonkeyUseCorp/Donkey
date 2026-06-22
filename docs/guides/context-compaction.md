# Context Compaction

A conversation can run for many turns and steps, and every one appends to the conversation record. A model has a bounded context window, so the harness can't feed the whole history back each step. Compaction is how Donkey keeps a complete record on disk while handing the model only a small, high-priority slice of it — the same approach Claude Code takes: summarize older turns forward, carry recent ones verbatim. The word covers two jobs: building the rolling context the planner reads each step, and writing the end-of-run summary that sits beside the record.

**The one rule:** the model never sees the raw `conversation.md`. Each step it sees a bounded, priority-ranked view — recent conversation events plus a rolling summary of older ones — and when that view outgrows its budget the older turns are summarized into a fresh summary event the next steps read instead. If a step needs an old detail to stay coherent, pin the event or rely on the rolling summary; don't widen the window, because the compactor clips and drops to fit its budget regardless.

## How It Works

The conversation record (`conversation.md`) is the full, append-only conversation and trace. Beside it the harness keeps the same events as structured data. The two compaction paths read from these and serve different consumers:

```text
conversation events (structured) ──> rolling compaction ──> bounded step context ──> planner
                                            │
                                            └─ over threshold ──> summarize older turns ──> new summary event
conversation.md (full markdown)   ──> end-of-run summary  ──> summary.md ──> conversation view / next session
```

The division of labor: **rolling compaction decides what the model reads next; the end-of-run summary decides what a human (or a later session) reads as the digest.** Rolling compaction runs before every planner call; the end-of-run summary runs once when the run finishes. Both leave the full `conversation.md` untouched — see [Conversation Record](conversation-record.md) for the append-only writing rules.

## Rolling Context

Before each step the compaction driver loads the conversation's events, assets, and active agents, then selects a bounded subset. The strategy keeps four classes of events and merges them, so an important early event still survives even after dozens of later ones:

| Class | What it keeps | Why |
|---|---|---|
| Pinned | the most recent pinned events | events explicitly marked must-survive |
| Summary | the last two summary events | the rolling digest of older history |
| Tool | the most recent tool-result events | what the agent just observed and did |
| Recent | the last several events of any kind | immediate continuity |

Each selected event's text is clipped to a per-event character cap. Assets are capped newest-first. Active agents are kept; finished ones drop out. The selection is rendered to one context string, clipped to a whole-prompt budget, and handed to the planner, which renders it under a `CONVERSATION SO FAR` block — distinct from the current run's tool-history block, which is "what I did this run" rather than "what this conversation is about."

When that rendered context grows past the summary trigger, the driver summarizes the turns about to age out into a new summary event and writes it back into the conversation; the next step's selection picks it up automatically (the summary class above), so older raw turns fall away while their gist stays. A debounce keeps it from re-summarizing every step once near the trigger. The defaults are deliberately small — roughly a dozen recent events, a handful each of pinned and tool events, an eight-thousand-character prompt ceiling, and a six-thousand-character summary trigger below it — and live in one policy struct so the budget is tuned in one place.

Each turn also records a compaction snapshot: which event, asset, and agent ids it included, the resulting prompt size, and a per-class record of how many items were original, included, dropped, and truncated. The snapshot is the audit trail for "why didn't the model remember X" — if an event isn't in the snapshot's included ids, it wasn't in that step's context.

## End-Of-Run Summary

When a run finishes, the harness writes a structured brief to `summary.md` with fixed sections: goal, progress, key decisions, next steps, and critical context. It lands in two stages. A deterministic summary, built from the run's steps and outcome, is written immediately so the digest is never missing. Then, in the background, a model rewrites it from the full `conversation.md` text and replaces the file. The background rewrite never blocks the run's result; if it fails or returns nothing, the deterministic version stays.

The summary is the compact carry-over for the next time the conversation is opened, and it is what the in-app conversation view shows as the conversation's digest.

## Rules

1. **The record is whole; the context is a slice.** Compaction only chooses what to forward to the model and what to digest for a reader. It never edits, truncates, or rewrites `conversation.md`. The rolling summary lives as an event in the structured store, not in the markdown record.
2. **Summarize forward, don't widen.** When the conversation outgrows the budget, the older turns become one rolling summary event; pinning is the only way to force a specific old event to stay verbatim.
3. **One budget, one place.** The caps — events, pinned, tool events, assets, per-event characters, whole-prompt characters, summary trigger, summary debounce — come from a single policy. Tune the budget there; don't special-case it per caller.
4. **Every selection is auditable.** Each turn records a compaction snapshot of what it included and dropped. Reach for the snapshot before assuming the model "ignored" something.
5. **The end-of-run summary degrades safely.** The deterministic summary is the floor; the model-written one is an upgrade applied in the background. A run's outcome never waits on the summary call.

## Where It Lives

The compactor, its policy, and the per-class selection live in the generic harness's conversation store. The rolling-summary driver runs the compactor each step, writes summary events back, and feeds the bounded context to the planner; it is wired into the run loop by the user-query command handler. The end-of-run summary — deterministic build and background rewrite — also lives in the command handler, and the files it writes are owned by the conversation transcript. Start with the compactor in the conversation store.
