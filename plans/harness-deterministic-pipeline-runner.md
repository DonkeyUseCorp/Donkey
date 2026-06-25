# Deterministic Pipeline Runner

Collapse fixed multi-tool recipes (shorts, PDF fill, future media pipelines) from
one planner round-trip per tool into a single routed action that runs the recipe
in code and calls the model only where judgment is genuinely needed.

## Why

A real shorts run — "make a 1-minute video with subtitles" — took **37
`gemini-3.5-flash` planning calls and $1.40**, all of it planner inference. The
work itself is a fixed recipe: per clip it is cut → transcribe clip → reframe →
burn subtitles → verify (`shorts/SKILL.md`), and the only genuine judgment in the
whole job is *which moments to clip*. Everything else is deterministic bundled-tool
work with a known next step.

The cost comes from the harness shape, not the work. `GenericHarnessRuntime.run()`
is observe → `planNextStep()` → execute → re-plan, **one LLM call per tool
boundary**. So `ffmpeg -vf subtitles=…` — a command whose next step is already
known — still pays for the model to "decide" to run the next known command. Three
clips × ~11 tool steps + understanding + retries (`maxPlanAttempts = 3`) +
verification reads ≈ 37. The per-call price also climbs ($0.012 → $0.128) as the
12-step history window fills with 4 KB tool results and the static prefix (full
tool catalog + skills + lessons) is re-sent every call.

## The pattern already exists

`pdf.fill` already does this for forms:

```
pdf.fill (tool)                 GenericHarnessToolRegistry.swift:750
  → formFill executor           GenericHarnessBuiltInToolExecutors.swift:2405
  → services.formFiller         wired in UserQueryCommandHandler.swift:796
  → FormFillOrchestrator.fill   FormFillOrchestrator.swift
       read form  (bundled tool, no planner)
       map data → fields         ← the ONE model call (HostedFormMapper)
       write + verify (bundled tool + file check, no planner)
```

The orchestrator runs bundled tools through `DonkeyCommandBackends.runBundledTool`,
which bypasses the model-facing `shell_exec` gate, and verifies from the tool's own
JSON report plus the file on disk — no LLM in the loop. The planner sees one tool
call and one result.

This plan generalizes the *mechanism* so a new recipe is a thin declaration rather
than a hand-written orchestrator, and migrates `pdf.fill` onto it.

## Design

A `PipelineRunner` (DonkeyRuntime) executes a typed `Pipeline` of stages against a
small named-state bag (artifact paths + scalars). Stage kinds:

- **tool** — run a bundled tool with args templated from state; capture its
  structured result into state. No planner, no `shell_exec` gate.
- **decide** — the only model call. Build a bounded prompt from state, parse
  structured output (a map, a list of spans), write it back to state. Injected as a
  closure, exactly like `FormFillOrchestrator`'s `mapper`, so the runtime stays free
  of provider detail.
- **fanOut** — run a sub-pipeline per item in a state list (one clip pipeline per
  selected moment). This is what makes N clips cost one decision, not N×11 calls.
- **verify** — a code predicate over tool reports / file existence / `ffprobe`. A
  failure carries a real reason back, no LLM round-trip.

The runner returns a `PipelineOutcome` (summary text, produced files, succeeded) —
the same shape as `HarnessFormFillOutcome`.

Each recipe is exposed as **one tool** whose executor builds its `Pipeline` and
runs it. The planner dispatches it with a normal validated tool call after
understanding — the model boundary and "never string-match raw input" rule are
untouched; the pipeline is selected the same way `pdf.fill` is today.

```
  TODAY (per clip ≈ 11 planner calls)        RUNNER (whole job ≈ 2–3 calls)
  plan→cut →LLM                              planner emits ONE tool call: shorts.make
  plan→transcribe →LLM                                 │
  plan→pick text →LLM                        ┌─────────▼──────────────┐
  plan→reframe →LLM                          │ PipelineRunner          │
  plan→burn →LLM                             │  decide: pick moments ← 1 model call
  plan→verify →LLM                           │  fanOut per moment:     │
  ×N clips + retries                         │    cut/transcribe/      │  no LLM
       37 calls · $1.40                      │    reframe/burn/verify  │
                                             └─────────────────────────┘
```

## First consumers

- **shorts** (`shorts.make`). One `decide` (pick moments) → `fanOut` per clip:
  cut → transcribe → reframe → burn → verify. `shorts/SKILL.md` routes to the tool.
- **caption/translate** (`media.caption`). The trace of a real "1-min clip + Korean
  overlay" run showed the generic failure in full: ~5 logical steps became 37,
  because the planner hand-built and then *debugged* the plumbing — a model-authored
  SRT came back messy (→ re-clean → Python filter), the burn failed on a default
  encoder (→ probe `ffmpeg -encoders`), a `-c copy` trim gave the wrong duration (→
  eight `ffprobe`s) — each probe a full-context LLM round-trip. `media.caption` does
  it as code: on-device transcribe → optional ONE translate call → SRT built in code
  → burn with `libx264 -pix_fmt yuv420p -c:a aac` → verify. `media/SKILL.md` now
  routes subtitle/translation work to it instead of narrating the manual recipe.
- **pdf.fill** (migrate, pending). Re-express `FormFillOrchestrator` as a one-`decide`
  pipeline so all three share the runner.

The generic lesson (now applied twice): **a deterministic multi-tool recipe belongs
behind one tool on the shared runner, and its skill routes to that tool** — never a
prose recipe the planner steps through and debugs. Caching/trimming shave per-call
cost; this is what removes the calls. Shared machinery: `MediaPipeline` (run/verify/
fanOut) and `MediaSubtitles` (cue grouping + SRT) back both media tools.

## What should be done next

1. ~~Add the runner in DonkeyRuntime with code verification and `runBundledTool`
   dispatch; unit-test that no planner call happens between deterministic stages.~~
   **Done.** `MediaPipeline` (`runStep` + `fanOut`) in DonkeyRuntime, with
   `ShortsOrchestratorTests.multiClipRunMakesExactlyOneModelCall` asserting a
   two-clip job makes exactly one model call.
2. ~~Expose `shorts.make`: descriptor + executor → `services.shortsMaker` wired in
   `UserQueryCommandHandler`; rewrite `shorts/SKILL.md` to route to it.~~ **Done.**
   `ShortsOrchestrator` (DonkeyRuntime) + `HostedMomentSelector` (DonkeyAI) is the
   one model call; the skill now points the planner at the tool.
3. Migrate `pdf.fill` onto the runner; keep `HostedFormMapper` as its `decide`
   closure. Delete the bespoke loop body once parity holds. (Lower priority —
   `pdf.fill` already makes one call, so this is code unification, not a cost fix.)
4. Capture the new trace (call count + cost) on a real shorts run and record it
   against this plan's "Why" numbers.

## Where the code lives

- `apps/Donkey/Sources/DonkeyRuntime/MediaPipeline.swift` — the shared runner
  primitives (`runStep`, `fanOut`, code verification).
- `apps/Donkey/Sources/DonkeyRuntime/ShortsOrchestrator.swift` — the shorts
  pipeline: resolve → transcribe → select (one model call) → fan out per clip.
- `apps/Donkey/Sources/DonkeyAI/HostedMomentSelector.swift` — the one bounded
  inference (transcript → spans), modeled on `HostedFormMapper`.
- `shorts.make` descriptor/executor/service in `GenericHarnessToolRegistry.swift`
  and `GenericHarnessBuiltInToolExecutors.swift`; wired in `UserQueryCommandHandler`.

## Secondary cost levers — per-call INPUT tokens

A planner call is ~99% input (e.g. 59,293 input / 109 output): the cost is the
prompt we send, not the answer. The static `instructions` slot (doctrine + all 39
tool descriptors + skills, ~11K tokens) is byte-identical every step; the dynamic
`input` slot (history + turnState + a screenshot) changes each step.

Landed:

- **Skip the screenshot on app-less turns** (`UserQueryCommandHandler`). It captured
  whatever window was frontmost every step — irrelevant on a headless run and never
  cacheable. Gated on the structured `actionSurface`.
- **Scope the tool catalog by task** (`PlannerToolScope`). An app-less turn drops the
  9 GUI-only tools (AppleScript pipeline, app-learning, path-visualizer); see/act and
  capability tools stay. Driven by structured understanding, not raw text.
- **Surface cached vs uncached input** in the usage UI (`UsageHistoryCard`): an
  explicit "Cached input (N%)" per call and a "% cached" rollup per conversation, so
  whether implicit caching is hitting is now visible instead of inferred.

Also landed:

- **Explicit Gemini context caching** of the stable system instruction
  (`gemini-context-cache.ts`, wired into the Gemini adapter's `createResponse`). On
  Vertex (no implicit caching), the ~11K-token instructions block was re-billed in
  full every step; now it's cached once (keyed by a content-hash `displayName`) and
  referenced, so it bills at the cached rate. Serverless-safe (the cache lives in
  Gemini's registry, found by list-or-create with a warm-instance memo) and fully
  fail-safe (any error falls back to the inline instruction). Behavior-neutral.
  Real-world confirmation comes from the cached-share dashboard — if Vertex rejects a
  system-instruction-only cache on the `global` endpoint, the share stays low and the
  next step is to cache `contents` or use a regional endpoint.

Dynamic half — what caching can't touch:

- **Capped decision-input replay** (`harnessDecisionValueMaxLength` +
  `clippedDecisionInputValue`, applied in `renderDecision`). Past-step *results* were
  already capped, but a past *decision* replayed its full raw input every step it
  stayed in the window — so one `files.write content` or long `llm.generate` prompt
  re-sent those tokens on every step. Oversized values are now clipped.
- The other dynamic pieces are already bounded and were left alone: `workspace.files`
  inlines only small text files (≤16 KB, ≤6 files, ≤4 K chars total); results cap at
  600 / 4 000 chars; the detailed history window is 12 steps. Their caps carry
  documented loop-prevention rationale, so don't loosen or tighten them blind.
- The cached-share dashboard now decomposes a call: cached ≈ the static prefix,
  `input − cached` ≈ the dynamic half. Use it to decide whether more dynamic trimming
  is worth it before cutting anything else.

Still pending:

- Harden planner JSON so malformed replies stop burning the 3-attempt retry budget.

## Non-goals

- No skill-authored DAG-in-markdown. Recipes are typed Swift pipelines built on the
  shared runner; skills stay prose and point the planner at the tool.
- No change to the model boundary or intent routing. Recipes are dispatched as
  ordinary validated tool calls after understanding.
- Not a general "let the planner batch arbitrary tools" feature — this is for fixed,
  known recipes only. Open-ended work stays in the re-planning loop.

## Risks

- A recipe that needs mid-pipeline judgment (a clip that fails to reframe and needs
  a different crop) must surface cleanly back to the planner rather than silently
  degrading. The `verify` stage returning a real reason is the seam for that.
- Over-generalizing the stage model. Keep it to tool / decide / fanOut / verify
  until a third consumer proves another kind is needed.
