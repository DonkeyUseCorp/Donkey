# Decision System

## Purpose

Donkey treats every prompt, voice transcript, file drop, and follow-up as a
task-thread turn first. The decision system chooses whether the next step is a
conversation response, a clarification, a review flow, a guarded local-app
action, or no action for empty input.

Action is not the default. A local action starts only after a typed model or
runtime artifact says the turn is actionable and the runtime validates the
target, plan, permissions, and available control surface.

A runnable local task needs a clear action, a destination or target, and enough
payload to execute safely. Questions, greetings, malformed requests, and vague
local-task requests stay conversational or ask for a specific missing detail.

## Model Boundary

Pointer prompt turns are routed through bounded harness context. Semantic
decisions go through typed model boundaries; the supported hosted path uses the
authenticated Donkey backend Responses proxy with `store=false`, and the
backend chooses the concrete model.

The hosted decision output is strict `generic_harness_planning` JSON. It carries:

- structured intent
- ambiguity and risk
- context needs
- plan steps
- verification criteria
- fallbacks
- clarification policy

The generic harness stores those fields in task state. During the migration, the
local-app bridge decodes the structured intent into a `TaskIntent` only so the
existing catalog and live runner can execute the validated task.

Do not infer semantic intent by matching raw user text. Deterministic code may
match only typed model output, catalog fields, resolved app/item ids, tool names,
and other non-semantic runtime fields.

## Local App Plans

Models may choose only supplied task definitions and declared app capabilities.
`local_app_interaction` is the generic model-planned capability for app work
that has no more specific learned task definition.

When an app-finder catalog is supplied, executable app choices must resolve to a
`supported` catalog entry with a declared capability and control profile.
Candidate, unsupported, or denied entries are not executable targets.

Supported generic plan tools are:

```text
app.openOrFocus, app.observe, ui.newDocument, ui.focusSearch,
ui.focusAddressBar, ui.focusTextEntry, ui.setText, ui.pressReturn,
app.verifyCommand, app.verifyVisibleText
```

Plans that type text must provide the text as structured entity data, usually
`query`. Document-writing requests must contain meaningful final text; short
unquoted labels and copied prompt placeholders are not enough to open a writing
app. Media requests that name only an artist, genre, or seed must choose a
concrete playable song, album, or playlist before execution.

## Validation

Before execution, Donkey validates model confidence, required entities,
app-finder metadata, target availability, allowed tools, permissions, and whether
the plan can be represented as guarded workflow steps.

The live runner owns launch/focus, observation, evidence-backed planning,
guarded input, verification, and recovery. Accessibility and keyboard input run
through action-engine guardrails. AppleScript may run only from typed task
metadata or validated generated artifacts; free-form planner text is never
direct input.

Agent visualization is evidence-derived. Normal local-app tasks may publish
cursor playback only from observed controls, action traces, or other grounded
runtime evidence; visual-only demonstrations use the same plan shape without
live input.

## Learning

Reviewed or successful plans can become reusable runtime task definitions in
agent memory. That keeps the supported path generic: typed decision, catalog
validation, guarded execution, verification, and optional memory-backed learning.

The app-finder catalog is seeded from bundled profiles and refreshed from the
user's installed applications. Generated profiles are sanitized to generic
control profiles before they can influence executable planning.

## Source Entry Points

- Prompt handling: `apps/Donkey/Sources/Donkey/PointerPromptCommandHandler.swift`
- Hosted decision adapter: `apps/Donkey/Sources/DonkeyAI/HostedTaskIntentParsingAdapter.swift`
- Catalog validation: `apps/Donkey/Sources/DonkeyRuntime/LocalAppTaskCatalog.swift`
- Generic lifecycle bridge: `apps/Donkey/Sources/DonkeyRuntime/AppHarnessGenericLifecycle.swift`
