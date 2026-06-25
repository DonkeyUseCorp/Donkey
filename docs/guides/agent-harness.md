# Agent Harness

The Agent Harness is the runtime that turns a user request into completed work
on a Mac.

Its job is simple: understand what the user wants, choose the next action,
execute it safely, verify the result, and continue until the task is complete.

The harness is intentionally generic. It knows how to plan, observe, act,
verify, recover, and learn. It does not contain knowledge about individual
applications. App-specific behavior lives in skills, catalog data, generated
artifacts, plugins, and memory.

This separation keeps the runtime small and predictable. The harness provides
the execution model; skills provide domain expertise.

## How a Task Runs

A task is a sequence of small verified steps rather than a single model
completion.

```text
user request
    |
    v
understand the task
    |
    v
build task state
    |
    v
choose the next action
    |
    v
validate
    |
    v
execute
    |
    v
record the result
    |
    v
repeat until complete
```

The model chooses the next action. The harness validates it, executes it,
records the result, and decides whether more work is required.

Planning happens continuously. The system observes the current state of the
world, performs one action, records the outcome, and then decides what to do
next. Every step is based on fresh evidence.

The loop is built to fail forward. Each action produces new information, updates
the task state, and moves the task toward completion. Existing results are
reused, completed work is recognized, and progress is measured against the goal
at every step.

The task stops only when it reaches a successful outcome, requires user input,
requires permission, or encounters a condition that cannot be resolved safely.

## Task State

Every task maintains its own state throughout execution.

Task state contains:

- the goal
- structured intent
- the current world model
- the execution plan
- tool history
- pending work
- granted permissions
- lifecycle status

Tasks are isolated from one another. Pausing, clarifying, interrupting, or
cancelling one task does not affect any other task.

Multiple tasks can make progress at the same time. A request that continues an
existing task is added to that task's execution loop. A new request creates a
separate task.

If execution stops before completion — for example because a step limit is
reached or an application closes unexpectedly — the task remains resumable and
can continue later.

## Storage

The harness stores two kinds of information.

**Threads** record the conversation and execution trace. The trace captures
model decisions, tool calls, observations, outcomes, timing information, and
recovery attempts.

**Task snapshots** store execution state so work can continue across
interruptions.

When a task finishes, the harness may extract a small operating lesson from the
run. Relevant lessons can be reused by future tasks with similar goals, allowing
the system to improve over time without changing the core runtime.

## Understanding the Request

Before the loop begins, the harness reads the request once and turns it into a
stable goal. Every later step plans against that goal rather than the original
words.

**The one rule:** the harness never decides meaning by matching raw text. A
request always passes through a model or another typed boundary first. After
that, code may match structured fields — tool names, app ids, file paths,
permissions — but never the raw string. If you are tempted to branch on whether
the request contains the word "music," that logic belongs in a skill, not the
runtime.

Understanding first decides the kind of turn:

- A conversation turn — a greeting, a thank-you, a question answered in words —
  goes to a responder that holds no tools and never touches the action loop.
- An action turn reaches the planner and the Mac.
- A clarification turn asks the user a question before anything else.

Action is unreachable until the turn is typed as an action, so conversations
come first by construction.

For an action turn, the same step also:

- names the target app, or marks the turn app-less — work done through system,
  web, and generative tools with no app involved at all
- extracts the parameters and what success will look like
- decides whether clarification is needed
- chooses background or foreground

Background is the default: the agent works without taking over the cursor or
raising the app. Foreground is the exception, used when the user is meant to
watch — pulling something up, walking through a flow.

Files the user attaches are described to this step by name and type, never by
their contents, so the goal is read against them: "turn this into a headshot,"
"summarize these." Their paths reach the planner as inputs it can read and act
on through the general file, image, and document tools.

The context sent to the model is always bounded. The harness keeps the current
turn, relevant task state, recent useful evidence, summaries, memory, and
pending questions — never unbounded raw history.

The app catalog is part of this step. If a requested app or capability is not
supported, the harness surfaces conversation, clarification, or a safe stop. It
never silently executes an unsupported guess.

## The Model Boundary

The harness asks the model one question, over and over: given everything known
so far, what is the single next action?

Adapters translate that question into a specific provider's format and translate
the answer back. An adapter does three things:

- describe the available tools in the provider's format
- send the current task state as the prompt
- turn the response into one validated tool call, or an error

The model decides *what* to do; the harness decides *whether and how* it
actually happens.

Adapters never decide intent, run tools, or hold task state. Because every
adapter meets the same contract, swapping one provider for another — or adding a
fallback model that emits tool calls as plain text — changes nothing in the
loop. A bad reply, whether a refusal, a cutoff, or a malformed call, becomes an
ordinary harness state the planner already knows how to handle.

## Tools

Every tool is registered with a description: what it does, what it needs, which
permissions it requires, and how risky it is. The model reads the descriptions;
it never sees the implementation.

Model-facing text has three homes, chosen by how widely it applies:

- A **tool description** carries one tool's own contract and reaches the model
  only when that tool is offered.
- A **skill** carries one app's or domain's workflow and is surfaced when the
  task matches it.
- The **planner's core instructions** carry only what holds for every task, no
  matter the tool — retry discipline, see before acting, shell first.

Place a new fact by scope: one tool's detail goes on the tool, one domain's
workflow goes in a skill, and only universal doctrine goes in the core
instructions. Putting a single tool's detail in the core instructions is the
common mistake — it weighs on every turn and drifts out of sync with the tool it
describes.

Four situations stop the task instead of being pushed through:

| Situation | Result |
|---|---|
| Missing permission | wait for permission |
| Missing user detail | wait for the user |
| Dangerous ambiguity | ask before acting |
| Verification failure | re-plan: recover, clarify, or fail safe |

The tools cover conversation and clarification, permission requests, memory,
skills, app lookup, observation, UI actions, keyboard and pointer input,
waiting, shell commands, AppleScript, file understanding, web and text calls,
image and video creation, audio transcription, media editing, verification, and
lifecycle control.

The files a task produces are kept together. A conversation remembers what it
has written and where, so a growing task's output lands in one named folder
instead of being scattered.

## Shell First, GUI Second

Donkey works like an expert at the terminal. For anything a power user would
solve without a window — finding files, launching apps, reading and changing
settings — the planner reaches for a shell command first. Commands run from the
user's home directory, so a search for a file the user named lands in the right
neighborhood instead of walking the whole disk.

Driving a graphical interface is the fallback, used only when the task truly
needs it: a canvas, an Electron app, or a proprietary interface with no
command-line equivalent.

Shell safety is based on consent, not a blocklist. Each command is sorted by its
tokens into a risk tier:

| Tier | Examples | Behavior |
|---|---|---|
| **read** | listing files, reading settings, checking power state | runs immediately |
| **reversible write** | changing a setting, opening an app | asks once, then remembers the choice |
| **high risk** | `sudo`, `rm`, `dd`, piping a download into a shell | asks every time, never remembered |

The planner discovers what is available by doing. It runs the command it needs
by name, and a "command not found" is just another observation it adapts to —
reaching for another tool or reporting what is missing. It never probes the
machine ahead of time and never installs anything.

Capability skills extend this terminal surface beyond what macOS ships — media
tools, image and document conversion, web capture. The uncommon command-line
programs those skills rely on are bundled inside the signed app, so the
capability works without the user installing anything, and they run immediately
like any trusted read.

## Seeing and Acting

Seeing and acting are ordinary tools the planner picks per step. After every
observation the harness re-plans: look, see the result, choose the next tool.

To see, the planner has two paths. Accessibility reads are fast and structured
and preferred for native apps. A screenshot with vision reads any pixels at all,
including a canvas or an Electron app. Both return elements into the world model,
which the planner reads as text — each element with its position, value, and
whether it can be clicked. With a multimodal model the compressed screenshot
goes along too, so the planner can point at things the structured reads miss.
Vision is paid for only when the planner chooses to look, and a fresh look at an
unchanged screen reuses the last parse.

A run is not bound to one app. Naming an app on a look step switches the run's
active target, and every later action resolves against that target — look at
Mail, act on Mail; look at Preview, act on Preview. An app-less run starts with
no target and acquires its first app the moment the planner looks at one.

Three things keep the planner aware of the whole screen. A look can widen its
scope from the window to the full display to all displays, and a click maps
correctly at any scope. When a modal popup is open, the read surfaces that
window, because its buttons and fields are what the planner needs. And the world
model lists every open window, so a request living in a background window exists
before the planner navigates to it.

To act, the planner can click an element, type or press keys, scroll, drag one
element onto another, wait for the app to settle, or run an AppleScript. Acting
on an Accessibility control resolves against the live element captured when it
was observed, so it stays correct even if the list reordered underneath it, and
it prefers the control's own native action — press, open, show menu — before
falling back to a click on its frame. Responding and asking for clarification
are tools too; sometimes the right action is a question.

Two invariants hold:

1. **Every input is guarded.** Focus, permissions, element eligibility, action
   type, and safety class all apply, and a coordinate click is never a shortcut
   around them. If the target window lost focus between looking and acting, the
   guard tries once to reactivate the target app — never any other app — before
   refusing, and a refusal names whatever is in front so the planner can react
   to it. On a background turn the guard delivers input straight to the target
   process without raising the app or moving the cursor, but it still refuses
   background for a sensitive surface like a login or a payment, falling back to
   the foreground path so the work still completes.
2. **Done means evidence.** A task is not complete because the right app is
   focused. The harness needs proof after the action — visible text, a selected
   state, an app-reported result, a screenshot-backed observation. A claimed
   completion whose last change has no later evidence is rejected, and the
   planner re-plans to verify first.

The animated cursor the user sees is cosmetic and separate from the real input.
The overlay narrates every step, not just clicks: steps that move the pointer
animate it, and steps that do not — looking, waiting, running a command — hold it
in place and update its label, so a silent step never looks like a hang. On a
background turn there is no real cursor to move, so progress is narrated through
the notch text alone.

## AppleScript

AppleScript is a tool path with a strict boundary: generation creates a script
but never runs it, and execution happens only through the guarded backend.

```text
generate (creates a script — does not run it)
    |
    v
validate
    |
    v
execute (guarded backend only)
    |
    v
observe
    |
    v
verify
```

Generation receives structured inputs and produces one bounded operation or a
very small sequence. It must not build a whole pipeline; observation, clicking,
recovery, and verification stay as separate harness steps. If the operation
cannot be expressed as a small scoped script, generation declines cleanly and
the plan falls back to Accessibility or the UI tools. The planner's own output
never contains script source — a separate generation step writes it.

Generated AppleScript is grounded in the target app's real scripting dictionary.
The runtime reads the app's dictionary into a typed model, cached per app
version, and that vocabulary flows through the whole path:

- The planner can ask for the app's declared commands, parameters, and classes
  as a bounded digest.
- Generation must use only that declared terminology, bind every required
  parameter, and report the commands it used. If the goal does not fit the
  dictionary, it declines instead of inventing syntax.
- Validation is deterministic. It rejects unresolved template tokens and
  commands the dictionary does not declare, then compiles the script against the
  dictionary — compile only, never launching the app. A compile failure carries
  the real compiler message back for another attempt.

A script that validates and runs successfully is promoted into a learned skill,
parameterized where a reported binding can become an input. The next run of the
same task goes straight through skill lookup, with no model-generated script at
all.

## Skills and Learning

Skills are reusable harness extensions: bounded instructions, descriptions, and
validated scripts the planner can look up. They are the sanctioned home for
app-specific knowledge that must never enter core runtime code.

Learning an app is itself a harness task that produces a skill. It gathers
bounded screenshot and Accessibility evidence, explores only safe and reversible
states unless the user approves more, distills a profile and a few workflow
recipes, and saves a reusable skill with any validated scripts.

Learned skills compound across sessions. A saved skill declares the app it
serves and is rediscovered alongside the bundled ones, so a later run driving
that app loads its learned playbook exactly like a built-in.

Skills come from three sources, merged in priority order: **built-in**, shipped
in the app; **installed**, added from the catalog and verified at install time;
and **learned**. A built-in always wins a name collision, so installing a skill
can never break a curated one.

## Where the Code Lives

The harness, registry, tools, skills, and thread storage live in the harness
module; guarded execution, Accessibility, screenshots, and input backends live
in the runtime module; model routing and adapters live in the AI module. Start
in the harness module when changing how a task is planned and run.
