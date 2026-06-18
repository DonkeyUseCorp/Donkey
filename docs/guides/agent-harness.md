# Agent Harness

The agent harness is the runtime that turns a user request into completed work
on the Mac. It is app-agnostic: it knows how to plan, act, verify, and recover,
but it knows nothing about specific apps. Everything app-specific lives outside
the core — in task definitions, catalog data, skills, generated artifacts,
plugins, or memory.

**The one rule:** core harness code never contains phrase lists, app-name
branches, or natural-language conditionals. If you're tempted to write
`if command.contains("music")`, the logic belongs in a skill, the catalog, or a
typed model boundary instead.

## How a Turn Works

A task is not one big model completion. It's a loop of small steps, each one
checked before and after:

```text
user turn
  |
  v
1. Understand the turn (typed model boundary: goal, target app, parameters)
  |
  v
2. Compact context into task state (never raw history)
  |
  v
3. Ask the model: "what is the single next tool call?"
  |        (see, act, verify, respond, clarify, or complete)
  v
4. Validate the call (registry, permissions, focus, safety class)
  |
  v
5. Execute it through the guarded executor
  |
  v
6. Record the structured observation into the world model
  |
  v
7. Loop back to 3 — or hard-stop at a permission / clarification gate
```

The model decides *what* to do next; Swift decides *whether and how* it
actually happens. The model picks the tool. Swift owns task state, validation,
focus checks, permission gates, execution, and recording results.

Planning happens per observation, not as one upfront plan. The harness looks,
acts, sees what happened, then picks the next step.

## Task State

Every task carries its own durable state:

- goal and structured intent
- world model (what the harness currently believes about the screen and system)
- plan, tool history, and pending continuation
- granted permissions
- lifecycle status (running, paused, `waitingForUser`, `waitingForPermission`,
  interrupted, resuming, completed, failed-safe, timed-out, cancelled)

State is task-local. Pausing, clarifying, gating, interrupting, or cancelling
one task never touches another — and because each task runs its own loop, several
tasks make progress side by side. A new request that continues a task already
running is folded into that task's loop and picked up at its next step rather
than restarting it; an unrelated request starts a new task that runs alongside.
A task whose loop is torn down before it finishes (it hit the step ceiling, or
the app quit mid-run) is left retryable, not failed.

Storage keeps decisions inspectable:

- **Threads** store the conversation *and* the turn trace, in the same thread
  file. The trace records every model call (clipped prompt and reply, finish
  reason, attempt, outcome, and duration), which sensing modality each step used
  (Accessibility vs. AI vision), and the per-step split of decision time vs.
  tool time. Timestamps are wall-clock plus monotonic, so a slow turn is pinned
  to a specific call instead of a coarse end-to-end number.
- **Task snapshots** store execution state.

One turn-trace manager is the single sink every model call and the step loop
report to — the substrate a later self-correcting pass would learn from.

## Turn Understanding

Two rules govern how the harness reads a user request:

**1. Never match raw user text.** Semantic intent always passes through an LLM
or another typed boundary first. After that, deterministic code may match
*typed fields* — tool names, app ids, schema values, permissions, file paths,
Accessibility roles — but never the raw string.

**2. Understand once, then loop.** Before the per-step loop starts, an
understanding boundary restates the goal, names the target app (or leaves it
empty for system-tool tasks), extracts parameters and success criteria, flags
whether clarification is needed, and chooses whether the work runs in the
background (the agent acts without taking over the cursor or raising the app)
or the foreground (the user is meant to watch — pulling something up, a
walkthrough). Background is the default; foreground is the typed exception, and
like every other field it is decided here, never matched from raw text. Every
later step plans against this stable, typed goal instead of re-reading the
user's words.

Context sent to the model is always bounded. Compaction keeps the current
turn, relevant task state, recent useful evidence, summaries, memory snippets,
pending questions/permissions, and bounded assets — never unbounded raw
history.

The app catalog is part of this boundary. If a requested app or capability
isn't supported (or is still refreshing), the harness surfaces conversation,
clarification, waiting, or failed-safe state. It never silently executes an
unsupported guess.

## Model Boundary and Adapters

The harness asks an abstract boundary one question: "given this task state,
what is the single next tool call?" Adapters translate that question into a
specific provider's wire format and parse the answer back. Adapters live in
`DonkeyAI/`; the planner and task state never see provider details.

An adapter's job is narrow:

```text
next-tool-call request
-> render registry tool descriptors into the provider's tool format
-> send compacted task state as the prompt
-> parse the response into one validated registry tool call, or an error
```

Because adapters are interchangeable, a fallback adapter — including one for
an open-weights model that emits tool calls as structured text — is a drop-in
shape: it implements the same render/parse contract against the same registry
and changes nothing in the runtime loop. Format-specific parsing stays inside
the adapter; the rest of the harness only ever sees a validated tool call.

Adapters never decide intent, execute tools, or hold task state. Provider
failures (refusals, truncation, malformed calls) map into harness states the
planner already handles — no ad hoc retries inside the adapter. Planner-side
failures are bounded honestly too: a malformed or empty model reply is retried
with the failure fed back, and an empty tool name never reads as completion.

## Tools

Every tool is registered through the generic registry with a descriptor: name,
plugin id, schemas, required permissions, safety class, required context,
verification hints, and metadata. The planner sees descriptors and schemas,
never Swift implementations.

Tool results come back as structured observations that update the world model.
Four situations are hard stops, not things to push through:

| Situation | Result |
|---|---|
| Missing permission | task → `waitingForPermission` |
| Missing user detail | task → `waitingForUser` |
| Dangerous ambiguity | ask before acting |
| Verification failure | re-plan: recover, clarify, or fail safe |

Core tool families: conversation, clarification, permission requests, memory,
skills, app lookup, observation, UI element actions, text/keyboard input,
pointer input (scroll, drag, click variants), waiting, shell commands,
AppleScript generation and execution, file understanding and file asks,
verification, learning, and lifecycle control.

## Shell First, GUI Second

Donkey works like an expert terminal user. The planner's first choice is
`shell_exec` for anything a power user solves without the GUI:

- finding things: `mdfind`, `find`, `ls -t`
- launching/quitting apps: `open`, `osascript`
- reading state: `pmset -g`, `system_profiler`, `defaults read`
- changing settings: `defaults write`, `networksetup`

Driving a GUI is the fallback, used only when the task truly needs it (canvas,
Electron, or proprietary interfaces with no command-line equivalent). This
preference lives in the planner doctrine and a built-in `system-tools` skill.
For system-tool tasks the understanding boundary leaves the target app empty,
so they're never pinned to a GUI app.

Shell safety is consent-based, not denylist-based. Each command is classified
by its argv tokens (typed fields, never natural language) into a risk tier:

| Tier | Examples | Behavior |
|---|---|---|
| **read** | `mdfind`, `defaults read`, `pmset -g` | runs immediately |
| **reversibleWrite** | `defaults write`, `open`, `networksetup -set…` | consent gate: Allow Once / Always Allow (rule keyed on command signature, persists) |
| **highRisk** | `sudo`, `rm`, `dd`, `curl \| sh`, anything touching `com.apple.TCC` | asks every time, can never be remembered |

Consent surfaces in the pointer/notch overlay and reuses the standard
`waitingForPermission` gate. A capability probe records which command-line
tools (and versions) exist on the machine, so the planner only reaches for
what's installed.

Broad capability skills extend this power-user surface beyond the tools macOS
ships — media (`yt-dlp`, `ffmpeg`), images, PDF/document conversion, data
manipulation, and web capture. The uncommon command-line tools those skills
rely on are bundled inside the signed app, so the capability works without the
user installing anything.

## Observation and Action (Computer Use)

Seeing and acting are plain tools the planner picks per step — not a fixed
pipeline. The harness re-plans after every observation: look, see the result,
pick the next tool.

**To see**, the planner draws on two paths: Accessibility reads (fast,
structured, preferred for native apps) and screenshot + vision (any pixels —
canvas, Electron). Both return elements into the world model, which the planner
reads as text: each element with its geometry, value, and click eligibility, in
reading order. With a multimodal model the compressed screenshot goes too
(`ScreenshotCompression.compressedForModel` — ~896px JPEG), so the planner can
point at pixels AX and the vision parse miss. A non-LLM monitor re-parses on
large screen changes, keeping the vision cache warm so captures are usually free
at decision time.

Three things keep the planner aware of the whole screen, not just the front
window. Capture widens in scopes, smallest first — `scope=window` (default),
`scope=screen` (the display, for things drawn outside the window like a modal
sheet or right-click menu), `scope=desktop` (all displays, when the target is on
another monitor); detected elements carry the rect they were found in, so a
click maps through it the same way at any scope. When a modal popup is open the
Accessibility read surfaces *that* window — its buttons and fields are what the
planner needs. And the world model lists every open window (app, title, bounds),
so a request living in a background window exists before the planner navigates
to it.

**To act**, the planner can click an element, type or press keys (including
modifier chords), scroll, drag one observed element onto another, wait for the
app to settle, or generate and run an AppleScript. Acting on an Accessibility
control resolves against the live element captured when it was observed — so it
stays correct even if a list reordered underneath it — and prefers a native
semantic action (press, open on a double-click, show-menu on a right-click)
that the control actually advertises, falling back to a guarded coordinate
click on the control's frame otherwise; vision elements click by coordinate.
Responding
conversationally and asking for clarification are also tools — sometimes the
right "action" is a question.

Two invariants:

1. **Every input is guarded.** Target focus, permission policy, element
   eligibility, allowed action type, safety class, and verification criteria
   all apply. Coordinate input is a fallback path, never a shortcut around
   these checks. If the target window lost focus between observe and act, the
   guard attempts one recovery activation of the target app (never any other
   app) before denying — and a denial names whatever is in front, so the
   planner can react to the blocking window instead of failing opaquely. On a
   background turn, the guard skips activation for a safe, on-screen target:
   a native Accessibility action runs as a focus-neutral cross-process call,
   and coordinate clicks, scrolling, dragging, and keystrokes are delivered to
   the target process directly — neither path raises the app or moves the
   cursor. The guard still refuses background for a sensitive surface (login,
   password, payment, system), falling back to the foreground activation path
   so the work still completes.
2. **Done means evidence.** A task isn't complete because the right app is
   focused. The harness needs post-action proof: a guarded command trace,
   visible text, selected state, an app-reported result, or a
   screenshot-backed observation. The runtime enforces this — a completion
   whose last state-changing step has no later succeeded evidence step is
   rejected, and the planner re-plans to verify first.

Pointer playback (the animated cursor the user sees — rotating, traveling,
labeling its path) is cosmetic and separate from input. AX, AppleScript,
keyboard input, or guarded coordinate fallback do the real work. The overlay
narrates every step, not just clicks: steps that move the pointer animate the
cursor, and steps that don't (observe, shell, wait, verify) hold it in place
and update its label, so a silent step never looks like a hang. On a background
turn the agent moves no real pointer, so the traveling cursor is suppressed and
progress is narrated through the notch text alone.

## AppleScript

AppleScript is a tool path with a strict artifact boundary — never a hardcoded
helper:

```text
automation.applescript.generate   (creates a script artifact — does NOT run it)
-> automation.applescript.validate
-> automation.applescript.execute (guarded backend only)
-> observe
-> verify
```

Rules:

- Generation receives structured inputs (target app, goal, entity, allowed
  actions, verification criteria) and produces *one bounded operation* or a
  very small sequence. It must not build a whole automation pipeline —
  observation, clicking, recovery, and verification stay as separate harness
  steps.
- If the operation can't be done as a small scoped script, generation fails
  cleanly and the plan falls back to observation, Accessibility, or UI tools.
- Planner output never contains raw script source. A child generation boundary
  creates the source, and the plan reuses the same `scriptArtifactID` across
  generate, validate, and execute.
- App-specific scripts live in skills, generated artifacts, plugins, catalog
  entries, or user-reviewed definitions. No app-named Swift helpers like
  `musicPlaybackScript`.

### Grounded in the App's Real Dictionary

Generated AppleScript is grounded in the target app's actual scripting
dictionary, not the model's memory of AppleScript. The runtime parses an app's
`.sdef` into a typed model, cached per app version, and that vocabulary flows
through the pipeline in three places:

- An `app_commands` tool gives the planner the app's declared commands,
  parameters, classes, and enumerations as a bounded digest, with per-suite
  drill-down. Non-scriptable apps get a deterministic redirect to the
  Accessibility/vision path.
- Generation receives the digest, must use only declared terminology, binds
  every required parameter, and reports the commands it used. If the goal
  doesn't fit the dictionary, it declines instead of inventing syntax.
- Validation is deterministic, not advisory: it rejects unresolved template
  tokens, rejects reported commands the dictionary doesn't declare, and
  compiles the script against the app's dictionary (compile only — no
  execution, never launches the app). A compile failure carries the real
  compiler message back to the planner for regeneration.

A script that compiles, validates, and executes successfully is promoted into
a learned skill pack — parameterized when a generation-reported binding can
become an input slot — so the next run of the same task goes straight through
skill lookup and `skill_run` with no model-generated script at all.

## Skills and Learning

Skills are reusable harness extensions: bounded instructions, descriptors, and
validated scripts the planner can look up — the sanctioned home for
app-specific knowledge that must never enter core runtime code.

Learning an app is itself a harness task that produces a skill. It gathers
bounded screenshot and Accessibility evidence, explores only safe/reversible
states unless the user approves more, distills an app profile and workflow
recipes, and saves a reusable skill pack with any validated scripts.

Learned packs compound across sessions: a saved pack declares its app in
`apps:` frontmatter and is rediscovered alongside the bundled packs, so a
later run driving that app preloads its learned playbook exactly like a
built-in. Bundled packs win when both name the same app.

Skills come from three discovered sources, merged in priority order: **built-in**
(shipped in the app bundle), **installed** (added from the catalog into the
on-disk install directory and verified at install time), and **learned**. A
built-in always wins an id collision, so installing a skill can never break a
curated one. Installed skills need not ship with the app — they are downloaded,
checksum/signature-verified, placed under a versioned `current` directory, and
picked up by the same discovery, so a turn can use them on its next step.

## Source Map

| Module | Owns |
|---|---|
| `apps/Donkey/Sources/DonkeyHarness/` | task state, registry, tools, skills, thread storage, generic runtime |
| `apps/Donkey/Sources/DonkeyContracts/` | shared contracts across modules |
| `apps/Donkey/Sources/DonkeyRuntime/` | guarded execution, Accessibility, screenshots, app/window observation, input backends |
| `apps/Donkey/Sources/DonkeyAI/` | hosted model routing and adapters; prompt doctrine in `DonkeyPrompts.swift` |
| `apps/Donkey/Sources/Donkey/` | user-query integration |

Tests live in `apps/Donkey/Tests/DonkeyRuntimeTests/`. Run focused
`swift test` from `apps/Donkey/` when changing harness behavior.
