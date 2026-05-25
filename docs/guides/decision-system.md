# Decision System

## What It Decides

Donkey treats every prompt, voice transcript, file drop, and follow-up as a task-thread turn first. The decision system chooses what the turn should do next:

- respond conversationally
- ask for a specific missing detail
- open a review flow
- run a guarded local-app action
- do nothing for empty or already-handled input

Action is not the default. A local action only starts after a typed model or runtime artifact says the turn is actionable and the runtime validates the target, plan, permissions, and available control surface.

A runnable task needs a clear action, a destination or target, and enough payload to execute safely. If the turn is a question, conversation, or malformed local-task request, the model should mark it as conversational in structured metadata and Donkey answers in the thread instead of opening an app.
For document-writing plans, Donkey also validates the model output itself: a short unquoted label-like payload is not enough to create or edit a document, even if the model selected Notes or another writing app.

## Decision Flow

The pointer prompt records the user-visible turn, builds a bounded context packet, and routes it through the harness. Empty input can be handled directly. Semantic decisions go through typed model boundaries. By default, task-intent and follow-up decisions use the authenticated Donkey backend Responses proxy with `store=false`; the Mac app does not send a concrete hosted model, because backend configuration chooses it. Local model adapters are not part of the supported decision path.

For local app work, the model receives:

- the current command
- supported runtime task definitions
- an app-finder catalog of installed apps with descriptions, support status,
  declared capabilities, and control profiles when available
- safety and execution expectations encoded in task metadata

The model returns strict JSON, not free-form instructions. The result is decoded into a `TaskIntent`. If the intent names an existing task definition, the catalog validates that definition. If it names the generic local-app interaction capability, the model must ground the selected app in the app-finder catalog when one was supplied. The catalog then resolves the requested app from local memory and app lookup, and materializes a transient task definition from the typed `actionPlan`.

For dynamic local-item capabilities, the app or item name comes from the typed model output. For dynamic local-app interactions, the app name is accepted only when it can be matched to a supplied app-finder catalog entry with `supportStatus=supported` and a selected declared capability. Catalog and memory matching happen after typed output exists, so lookup is scoped to structured fields such as `targetAppName`, `entities.appName`, `metadata.appFinder.selectedAppID`, or a resolved target id. That inference is not execution authority; the catalog still resolves and verifies the target before any action runs.

The `TaskIntent` wire format always includes an `actionPlan` object. Non-planned task types must return an empty `actionPlan.tools` array; non-empty action plans are accepted only for task definitions that explicitly opt into model-planned local-app interaction.
Conversational turns use `taskType: "none"` with an empty action plan,
`metadata.responseMode=conversation`, and `metadata.assistantResponse`; the
resolver preserves that response instead of turning it into an unsupported local
action failure.

## Generic Local-App Interaction

`local_app_interaction` is the default model-planned app capability. It exists for requests like "play some Justin Bieber" where the user is not asking to merely open an app, and no durable app-specific task definition has been learned yet.

For this capability the model must provide:

- `targetAppName`, such as `Music`
- `entities.appName`
- `entities.goal`
- `entities.query` when text needs to be entered
- `actionPlan.tools`, a typed sequence of allowed local tools
- `actionPlan.inputEntity`, usually `query` when `ui.setText` is present
- `actionPlan.controlID`, `actionPlan.focusKey`, and `actionPlan.verification` for the guarded UI strategy

When an app-finder catalog is present, the model must also provide:

- `metadata.appFinder.selectedAppID`
- `metadata.appFinder.selectedCapabilityID`
- `metadata.appFinder.controlProfile`

The selected app id must exist in the catalog, the catalog entry must be
`supported`, and the selected capability/control profile must be declared on
that entry. Catalog entries marked `candidate`, `unsupported`, or `denied` are
not executable targets.

The supported plan tools are intentionally small:

```text
app.openOrFocus
app.observe
ui.newDocument
ui.focusSearch
ui.focusAddressBar
ui.focusTextEntry
ui.setText
ui.pressReturn
app.verifyCommand
app.verifyVisibleText
```

The model may choose tools, entities, target app, and confidence. Website navigation should target Safari or the user's browser and use `ui.focusAddressBar` with a URL query. Simple document creation, such as writing in Notes or putting tabular text into Numbers, should use `ui.newDocument` and `ui.setText`. Unsupported tool names fail model-output validation or block before execution and become clarification/review instead of input.

## Runtime Validation

The catalog resolves dynamic targets through the agent memory store, Spotlight/app lookup, and bounded filesystem lookup. A planned action only proceeds when:

- model confidence is high enough
- app-finder metadata matches a supported app/capability when a catalog was supplied
- the target app or item is available
- required entities are present
- every planned tool is in the allowlist
- the plan can be represented as guarded workflow steps

The live runner then owns launch/focus, observation, evidence-backed action
planning, guarded execution, verification, and agent visualization evidence.
Accessibility and keyboard input run through action-engine guardrails.
AppleScript may be used only when supplied by typed task metadata or validated
generated artifacts; free-form planner text is never direct input.

Agent visualization is evidence-derived, not a separate command path for real
work. Normal local-app tasks may emit a final plan from evidence-backed action
steps, observations, and action traces after the runner has evidence; they do
not publish a pre-execution visualization from intent resolution. Cursor
playback only uses steps with grounded control bounds or action targets, so
background planning does not animate to invented points. Visual-only
demonstration requests use the same plan shape with `executionMode=visualOnly`
and no live input. In both cases, the overlay cursor is a visualization surface
only and does not move the real macOS pointer.

## Learning Boundary

Successful or reviewed plans can be stored as runtime task definitions in agent memory. That lets Donkey turn a one-off generic plan into a reusable supported capability without adding app-specific Swift fixtures or keyword lists.

Weather, Music, and document form-fill fixtures remain useful for tests and replay. The supported runtime path is generic: local app/item lookup, model-selected intent or plan, catalog validation, guarded execution, verification, and optional memory-backed learning.

The local app finder catalog is seeded from bundled JSON and refreshed in the background from the user's installed applications. Donkey persists a daily app-catalog snapshot under Application Support, compares it with the previously seen application ids, and sends only newly discovered apps through the typed catalog-profile model route. Generated profiles are persisted as JSON, sanitized to the allowed generic control profiles, and merged with the shipped seed; bundled deny/support entries remain authoritative.

## Source Entry Points

- Prompt command handling starts in `apps/Donkey/Sources/Donkey/PointerPromptCommandHandler.swift`.
- Harness routing and context packet assembly live in `apps/Donkey/Sources/DonkeyRuntime/AppHarnessTurnRouter.swift`.
- Task-intent parsing, app-finder prompt context, and the hosted Responses adapter live in `apps/Donkey/Sources/DonkeyAI/LocalGenerateTaskIntentAdapter.swift`.
- Catalog validation and generic local-app interaction materialization live in `apps/Donkey/Sources/DonkeyRuntime/LocalAppTaskCatalog.swift`.
- App-finder profile JSON loading and background refresh live in `apps/Donkey/Sources/DonkeyRuntime/LocalAppCatalogProfiles.swift`; hosted profile generation lives in `apps/Donkey/Sources/DonkeyAI/HostedLocalAppCatalogProfileGenerator.swift`.
- Guarded execution lives in `apps/Donkey/Sources/DonkeyRuntime/LocalAppTaskLiveRunner.swift` and the action-engine backends.
