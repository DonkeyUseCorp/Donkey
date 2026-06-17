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

Two hosted model boundaries make every semantic decision. Both call the
authenticated Donkey backend with `store=false`; the backend owns provider and
concrete model selection.

```text
user turn
  |
  v
1. Request understanding (once per turn)
   HostedHarnessRequestUnderstanding -> restated goal, target app (or none),
   parameters, success criteria, needsClarification + clarifying question
  |
  v
2. Per-step planning (loop)
   HostedHarnessStepPlanner -> one tool call per step: { tool, input, reason }
   Responding conversationally, asking for clarification, and requesting a
   permission are tools the planner picks like any other.
```

The model decides *what* the turn means and which tool comes next; Swift
decides *whether and how* the call runs. If understanding fails or times out,
the loop degrades to planning against the raw goal — it never blocks the turn.

## Outcomes

| Turn | Outcome |
|---|---|
| Empty or whitespace input | no-op decision; the prepared task completes immediately, no action runs |
| Question, greeting, chat | planner picks the respond tool; conversational answer, no action state |
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
| `apps/Donkey/Sources/Donkey/UserQueryCommandHandler.swift` | turn entry, outcome handling, visualization |
| `apps/Donkey/Sources/DonkeyAI/HostedHarnessRequestUnderstanding.swift` | one-shot request understanding |
| `apps/Donkey/Sources/DonkeyAI/HostedHarnessStepPlanner.swift` | per-step tool decisions |
| `apps/Donkey/Sources/DonkeyRuntime/AppHarnessGenericLifecycle.swift` | thread/task lifecycle and context compaction |
