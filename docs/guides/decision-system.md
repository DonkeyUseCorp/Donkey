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

The pointer prompt records the user-visible turn, builds a bounded context packet, and routes it through the harness. Narrow non-semantic primitives, such as empty input and numeric arithmetic, can be handled directly. Semantic decisions go through typed model boundaries.

For local app work, the model receives:

- the current command
- supported runtime task definitions
- relevant agent-memory snippets, such as installed local apps, files, folders, and learned task definitions
- safety and execution expectations encoded in task metadata

The model returns strict JSON, not free-form instructions. The result is decoded into a `TaskIntent`. If the intent names an existing task definition, the catalog validates that definition. If it names the generic local-app interaction capability, the catalog resolves the requested app from local memory and app lookup, then materializes a transient task definition from the typed `actionPlan`.

For dynamic local-item and local-app interaction capabilities, the app or item name may be directly stated, retrieved from memory snippets, or inferred as the likely default local app for the user's goal. That inference is not execution authority; the catalog still resolves and verifies the target before any action runs.

The `TaskIntent` wire format always includes an `actionPlan` object. Non-planned task types must return an empty `actionPlan.tools` array; non-empty action plans are accepted only for task definitions that explicitly opt into model-planned local-app interaction.

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
- the target app or item is available
- required entities are present
- every planned tool is in the allowlist
- the plan can be represented as guarded workflow steps

The live runner then owns launch/focus, observation, dry-run projection, guarded
execution, verification, and agent visualization evidence. Accessibility and
keyboard input run through action-engine guardrails. AppleScript may be used
only when supplied by typed task metadata or validated generated artifacts;
free-form planner text is never direct input.

Agent visualization is evidence-derived, not a separate command path for real
work. Normal local-app tasks emit a projected `AgentVisualizationPlan` before
execution, then may emit a verified plan from dry-run steps, observations, and
action traces. Visual-only demonstration requests use the same plan shape with
`executionMode=visualOnly` and no live input. In both cases, the overlay cursor
is a visualization surface only and does not move the real macOS pointer.

## Learning Boundary

Successful or reviewed plans can be stored as runtime task definitions in agent memory. That lets Donkey turn a one-off generic plan into a reusable supported capability without adding app-specific Swift fixtures or keyword lists.

Weather, Music, and document form-fill fixtures remain useful for tests and replay. The supported runtime path is generic: local app/item lookup, model-selected intent or plan, catalog validation, guarded execution, verification, and optional memory-backed learning.

## Source Entry Points

- Prompt command handling starts in `apps/Donkey/Sources/Donkey/PointerPromptCommandHandler.swift`.
- Harness routing and context packet assembly live in `apps/Donkey/Sources/DonkeyRuntime/AppHarnessTurnRouter.swift`.
- Task-intent model adapters live in `apps/Donkey/Sources/DonkeyAI/OllamaTaskIntentAdapter.swift`.
- Catalog validation and generic local-app interaction materialization live in `apps/Donkey/Sources/DonkeyRuntime/LocalAppTaskCatalog.swift`.
- Guarded execution lives in `apps/Donkey/Sources/DonkeyRuntime/LocalAppTaskLiveRunner.swift` and the action-engine backends.
