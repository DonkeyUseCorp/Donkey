# Donkey Architecture

A compact map of Donkey's supported runtime: what the major components are,
how a turn flows between them, and which guide owns each one. The source of
truth for behavior and boundaries is the guide linked in each row; this doc
only connects them.

**The one rule:** two boundaries carry everything. Model-backed decisions
cross the authenticated hosted backend (typed requests, `store=false`,
provider credentials never in the app); OS side effects cross the guarded
runtime (focus, permission, safety-class checks). Code that skips either
boundary — a direct provider call from the app, an input event outside the
guarded executor — is wrong by construction.

## Component Map

```text
                              macOS user
                                  |
+------------------------------ Donkey.app ------------------------------+
|                                 |                                      |
|  User Query Overlay             v                                      |
|  notch + prompt + spawned   typed turns (text, voice, follow-ups,      |
|  agent cursors              file drops)                                |
|         |                                                              |
|         v                                                              |
|  Thread/task lifecycle — durable threads, task state, compaction       |
|         |                                                              |
|         v                                                              |
|  Decision boundaries — understand the turn once, then plan one         |
|  tool call per step                                                    |
|         |                                                              |
|         v                                                              |
|  Generic harness loop — validate, execute, observe, verify             |
|     |            |                                                     |
|     |            +--> Guarded runtime: Accessibility, screenshots,     |
|     |                 keyboard/pointer input, shell, AppleScript       |
|     |                                                                  |
|  feeds on:                                                             |
|   - UI understanding engine (always-on AX + hosted vision fusion)      |
|   - Agent memory (SQLite FTS5 + local vectors)                         |
|   - Skills (built-in and learned packs)                                |
+-------------------------------------------------------------------------+
                                  |
                                  v
              Donkey backend (site/) — auth, credits,
              inference gateway, vision parsing
                                  |
                                  v
              Hosted model providers (credentials live
              here, never in the Mac app)
```

The overlay narrates; the harness decides; the guarded runtime acts; the
backend owns every provider. For the step-by-step turn loop, see the diagram
in `guides/agent-harness.md` — it is not repeated here.

## Components and Their Guides

| Component | Owns | Guide |
|---|---|---|
| User query overlay | notch surface, prompt composer, spawned cursors, turn entry, visualization | [`guides/user-query-overlay.md`](guides/user-query-overlay.md) |
| Decision boundaries | one-shot request understanding, per-step tool planning, outcome states | [`guides/decision-system.md`](guides/decision-system.md) |
| Agent harness | task state, tool registry, skills, the plan/act/verify loop, model adapters | [`guides/agent-harness.md`](guides/agent-harness.md) |
| UI understanding (Donkey Vision) | always-on fusion of Accessibility and hosted vision evidence | [`guides/donkey-vision.md`](guides/donkey-vision.md) |
| Skills | app-specific operating knowledge and validated scripts | [`guides/authoring-skills.md`](guides/authoring-skills.md) |
| Swift app structure | MVC split across `Donkey`, `DonkeyUI`, `DonkeyContracts`, `DonkeyRuntime`, `DonkeyAI` | [`guides/swift-mvc.md`](guides/swift-mvc.md) |
| Backend | auth, hosted credits, inference gateway, third-party Vision API | [`guides/backend-apis.md`](guides/backend-apis.md) |
| Site frontend | landing page and account views | [`guides/frontend-nextjs-guidelines.md`](guides/frontend-nextjs-guidelines.md) |
| Packaging and updates | app bundle, DMG, Sparkle, release workflows | [`guides/install-donkey.md`](guides/install-donkey.md), [`guides/releasing-donkey.md`](guides/releasing-donkey.md) |

## Durable Storage

| Store | Holds |
|---|---|
| Thread markdown (`App Support/Donkey/Threads/<id>/thread.md`) | conversation contents and full reasoning/tool trace ([how to write it](guides/thread-record.md)) |
| Core Data | durable task metadata, events, and assets for per-run coordination |
| Task and compaction snapshots | execution state, and exactly what context each model decision saw |
| Agent memory (SQLite, FTS5 + local vectors) | local-item records, negative lookups, runtime task definitions, bounded harness hints |
| Learned skill packs (app-support skills directory) | promoted playbooks and validated scripts |

## Legacy Subsystems

Some compiled code predates the hosted-model boundary and is not part of the
supported turn path. `DryRunReflexLoop`, `SlowPlannerSidecar`, the
planner-hint adapters, and the local JSON sidecar runner are referenced only
by themselves and debug tooling; live turns in `UserQueryCommandHandler` never
touch them. The local runtime onboarding window
(`LocalRuntimeOnboardingWindowController`) still runs at startup but conflicts
with the supported hosted boundary — treat all of these as legacy, not as
patterns to extend.
