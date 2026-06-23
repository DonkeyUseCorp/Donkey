# Decision System

How Donkey decides what a user turn becomes: a conversational answer, a
clarifying question, a permission request, guarded action on the Mac, or
nothing at all. Every prompt, voice transcript, file drop, and follow-up is a
task-thread turn first, and the mechanics of running an actionable turn live in
`docs/guides/agent-harness.md` — this guide covers only how the decision is
made and what each outcome means.

**The one rule:** action is never the default. A local action starts only
after a typed model boundary says the turn is actionable and the runtime
validates the tool call, permissions, focus, and safety class. If you're
tempted to decide actionability by matching the user's words —
`if command.contains("open")` — stop: semantic decisions belong to the model
boundaries below, and deterministic code matches only their typed output.

## How a Turn Is Decided

The first thing understanding decides is *what kind of turn this is* — and that
single typed fact routes everything after it. A conversation is answered without
the action machinery ever existing; only an actionable turn reaches the planner
and the Mac. This is the structural form of "conversations first": a misread
greeting can produce a slightly-off reply, never a command.

```text
user turn
  |
  v
1. Request understanding (once per turn)
   HostedHarnessRequestUnderstanding -> turnKind (converse | act | clarify),
   restated goal, target app (or none), parameters, success criteria,
   needsClarification + clarifying question
  |
  +--- turnKind == converse ---> Conversational responder
  |                              HostedHarnessConversationalResponder: one reply,
  |                              NO tools, no world model, no permission gate.
  |                              The reply streams into the notch; the turn ends.
  |
  +--- turnKind == act/clarify -> 2. Per-step planning (loop)
                                  HostedHarnessStepPlanner -> one tool call per
                                  step: { tool, input, reason }. Asking to clarify
                                  and requesting a permission are tools too.
```

Two facts make this safe by construction. First, `turnKind` is a typed enum the
model sets — deterministic code branches on it, never on the user's words.
Second, the conversational responder is handed no tool registry and no executor,
so it *cannot* drive the Mac even if the classification was wrong. The action
planner is only ever reached once a turn is typed `.act`.

The model decides *what* the turn means and which tool comes next; Swift decides
*whether and how* the call runs. If understanding fails or times out, the turn
degrades to the action path against the raw goal — the conservative default, and
it never blocks the turn.

## Outcomes

| Turn | Outcome |
|---|---|
| Empty or whitespace input | no-op decision; the prepared task completes immediately, no action runs |
| Question, greeting, chat (`turnKind == converse`) | conversational responder streams one reply; no action loop, no tools, no permission gate |
| Actionable with a clear target | guarded harness loop runs to completion with evidence |
| Actionable but missing a required detail | clarify tool → task `waitingForUser` with one specific question |
| Action needs an ungranted permission | permission request → task `waitingForPermission` |
| Cannot proceed safely | failed-safe with an honest report, never a silent guess |

A runnable local task needs a clear action, a resolvable target, and enough
payload to execute safely. Vague requests ask for the one missing detail
instead of guessing.

## Validation

Every planned tool call is validated before execution: the tool must exist in
the registry, its permissions must be granted, its safety class must allow the
action, and the target must pass the focus guard — frontmost for a foreground
turn, or a safe on-screen window driven cursor-neutrally (a focus-neutral
Accessibility action, or input delivered to the target process) for a
background turn. AppleScript runs only as
validated generated artifacts — free-form planner text is never executed
directly. Completion requires evidence: the runtime rejects a completion whose
last state-changing step has no later succeeded verification step.

## Visualization Is Evidence-Derived

The cursor playback users see is built only from grounded runtime evidence —
observed control bounds and succeeded action traces with screen coordinates —
never from planner text or invented positions. Harness path playback flows
through the `agent.path.visualize` tool, which returns a plan only after every
waypoint is grounded.

## Source Entry Points

| Module | Owns |
|---|---|
| `apps/Donkey/Sources/Donkey/UserQueryCommandHandler.swift` | turn entry, `turnKind` routing, outcome handling, visualization |
| `apps/Donkey/Sources/DonkeyAI/HostedHarnessRequestUnderstanding.swift` | one-shot request understanding, including the `turnKind` classification |
| `apps/Donkey/Sources/DonkeyAI/HostedHarnessConversationalResponder.swift` | the no-tools responder for a `.converse` turn |
| `apps/Donkey/Sources/DonkeyAI/HostedHarnessStepPlanner.swift` | per-step tool decisions on the action path |
| `apps/Donkey/Sources/DonkeyRuntime/AppHarnessGenericLifecycle.swift` | thread/task lifecycle and context compaction |
