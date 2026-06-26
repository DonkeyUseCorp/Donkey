# Harness Deep Dive

The architecture guide covers the loop, how a task keeps its state, where the
model decides, and how the tools are organized. This guide goes one level down:
how the individual parts work, one area per section. Read the architecture guide
first — everything here builds on it.

Every section obeys the three rules that guide already sets, so they aren't
repeated below: requests arrive as structured fields, never raw text; the model
proposes an action and protected code carries it out; and a step is done only
once something checks it worked. What follows is mechanics, not new
architecture.

## Task Lifecycle After the First Turn

A task is not over when its first run stops, and a running task is not sealed off
from further input. Four mechanics keep the lifecycle honest.

**Follow-up injection.** When the user sends a request while a task's loop is
still running, the request is queued onto that task. The loop drains the queue at
the top of each step and folds the text into the task's world model, so the next
planning step incorporates it. The goal and the work so far are untouched — the
agent keeps going with one more instruction, the way a queued chat message works.
That is the opposite of changing course, which replaces the goal and re-plans; a
follow-up only ever reaches a stopped task that way. Whether a request is a
follow-up to a specific task is decided by the typed follow-up boundary, never by
matching the text itself. Only recently active conversations are eligible: one
left idle past the staleness window counts as closed, so an unrelated later turn
opens a fresh task instead of folding into stale work.

**Concurrency.** Each task runs its own loop, and a loop releases control on every
await it makes for the model or a tool, so several tasks advance together. Two
unrelated requests become two tasks running at once rather than one stealing the
other. Background turns — the default — drive their target by process id without
raising an app or taking the cursor, so they never contend. Only a foreground
turn needs the visible screen, and foreground turns queue for a single focus
token, so two of them never fight over the front window.

**Resuming and timing out.** Pausing a task, or quitting the app, tears its loop
down; there is no suspended loop to pick back up, so resuming re-runs the task's
existing goal as a fresh loop. The stored world model and history carry the
context forward, so it continues rather than starting over. A run that stops
without finishing — it hit the step ceiling, or the app quit under it — is marked
timed out rather than failed, because the goal still stands and the user can
resume it. On relaunch, a task that was actively running moments earlier resumes
on its own in the background; one interrupted longer ago, or one that was waiting
on the user, comes back as a row the user resumes with a tap.

**Concluding a done-but-spinning run.** Sometimes a run finishes the real task —
it made a file or changed an app — but then gets stuck re-checking its own work,
or the planner runs out of moves. Rather than waste the rest of its steps or end
as a failure, the runtime marks it done, as long as there is clear evidence the
goal was met. A run that only ever read things, or that stopped because the user
is signed out or out of credits, is left alone so the user can retry or fix it.

## Lessons From Finished Runs

The harness improves itself across runs: a mistake it pays for once should steer
it the next time, without anyone editing a prompt.

When a run reaches a terminal state, a background pass reads the whole run — its
goal, its outcome, and the step-by-step trace — and asks the model for at most
one durable *operating lesson*: a general rule about how to work, like which tool
to reach for or which trap to avoid. The lesson must be reusable craft, not a
fact about this one task, file, or person; most clean runs teach nothing, and the
pass is expected to return nothing for them. A lesson worth keeping is stored as a
durable memory, deduplicated by its wording so re-learning the same rule refreshes
one entry instead of piling up copies.

At the start of a later run, the planner recalls the lessons whose subject
resembles the new goal and reads them near the top of its prompt, before it takes
the first step. So the agent that once spent a whole run on a search that timed
out begins the next, similar run already knowing the faster path.

This reuses the agent-memory machinery rather than adding a parallel store: the
same approval gate that refuses anything unlinked or sensitive, the same durable
storage, and the same ranked retrieval that surfaces app and file memories.
Lessons are just one more kind of memory in it.

One boundary keeps the cost down. Distillation runs only on a run that plausibly
taught something — one that failed, or one long enough to have taken a wrong turn
— so a quick success spends no model call.

## Files

File work splits in two. Understanding a file — figuring out what is actually in
it — is the hard, reusable part, so it earns its own step. The operation on it —
rename, resize, convert — is just the model deciding what to do from that
understanding, built from general actions. There is no built-in "rename" or
"suggest names" feature; that would freeze one request into the system instead of
letting the model compose it.

The flow is the same every time:

```text
look at the file → build a description of it → model decides what to do → carry it out → confirm it worked
```

### Understanding

Describing a file produces, for each one: what kind it is (text, image, PDF,
audio, video, or unrecognized), a short summary, any text found in it, its size,
and details such as image dimensions. A fixed, predictable step does the
classifying and the text reading — it asks the operating system what the file is,
and for a file with no extension it peeks at the first few bytes instead. None of
this involves the model. A separate step then fills in the harder types, such as
images and PDFs.

| Type | How it's read | What comes out |
|---|---|---|
| text, code, markdown | read the file's contents | the text of the file |
| image | recognize any text in the picture, read its size | the text found, the pixel dimensions |
| PDF | pull the text out | the document's text |
| audio, video | only classified for now | nothing yet — reading their contents is still to come |
| other, unknown | basic file info | type, size, dates |

Each description is remembered per file — keyed on its path, size, and
last-changed time — in one shared place, so describing a file and later acting on
it reuse the same result instead of reading it twice. Editing a file changes those
details, which throws the old description away.

### Operations

The model reads the description and acts; there is no separate feature per
operation.

- **Rename, tag, or sort** — the model turns the understood content into a name
  or label, a protected command applies it after asking you to confirm, and the
  result is checked by listing the folder again. This is the same split used for
  app automation: the model proposes, the protected step makes the change.
- **Resize, convert, or compress** — fixed image and video commands do the work,
  using the description only to fill in details like the current size or the
  original format.

### The working folder

Every conversation gets a dedicated working directory up front — a named folder
under the user's home (`~/Donkey/<goal-slug>-<id>/`), created before the first
action. It is where the shell runs and where a relative path resolves, so a
task's intermediate and output files land in one owned folder instead of loose at
the home root. The model decides naming and structure within it — it can group
related files into a subfolder — and a path the user spelled out is always used
exactly.

A conversation also carries a small, durable record of what it has produced and
where. Every file a tool reports writing is captured into it — from the result's
own path field, never by reading the user's words — and the record is shown back
to the model on every step, so it survives the context trimming that would
otherwise make the model forget what it made two turns ago. The filesystem stays
the source of truth; the record is a memory aid the model reconciles by listing
the folder when unsure.

The same record holds the turn's inputs. Files the user attaches are captured
alongside the agent's outputs — the input mirror of a deliverable — and surfaced
every step with their on-disk paths, so "turn this photo into a headshot" or
"summarize these" resolves against real files the model reads or edits with its
ordinary tools. The turn-understanding step is also told the attachments exist,
so an attached file reads the turn as action on that file rather than a
misclassified request. Any number of files can ride along; nothing here is
image-specific.

The folder is a kernel-enforced sandbox: every tool the agent spawns is confined to
write inside it, and the kernel blocks an escape even when the model errs. That
containment is why a bounded file operation whose paths all stay in the folder needs
no consent prompt — it changes nothing the user owns. A mutation that reaches outside
the folder asks first, and approval widens the sandbox for that one command. See the
[Workspace Sandbox](workspace-sandbox.md) guide for what a confined tool can read,
write, and reach.

### What stays fixed

- **Understanding is reusable; operations are not.** A new file request is the
  model combining the describe step with its general actions. A one-off "rename"
  feature would freeze a single request into the system.
- **A file's type is looked up, not guessed.** It comes from the operating
  system, or from the file's first few bytes when there is no extension — never
  from a hand-kept list of extensions, and never from the model.
- **The working directory is seeded; its contents are the model's.** The runtime
  creates the folder and resolves relative paths against it; naming, structure,
  and grouping inside it are the model's per-step judgments.
- **The sandbox bounds writes; consent governs the rest.** A spawned tool can write
  only inside the working folder — the kernel enforces it, so a stray or malformed
  path cannot reach the user's other files. Reads are open. Changing a file the user
  owns, driving another app, changing a system setting, or reaching the network is
  outside what the sandbox contains and gates on consent; an approved write then
  widens the sandbox just for that command.

### Where it lives

All of this lives together in the file-handling part of the harness: classifying
and reading a file, building its description, and handling the richer types like
images and PDFs along with the shared cache. Start there.
