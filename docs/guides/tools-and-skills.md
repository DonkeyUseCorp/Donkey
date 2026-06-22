# Tools and Skills

Donkey acts through a fixed set of registered tools, chosen by a fixed preference
order, with app-specific know-how supplied separately by skills. This guide is
the map: which tools exist, when each is reached for, how skills surface, and how
safety classes gate what runs without asking. Each tool's exact parameters live
in its descriptor in code, not here — this guide teaches the *when*, not the
schema.

**The one rule:** generic doctrine lives in the prompt, the capability lives in a
tool, and app-specific operating knowledge lives in a skill — never the other way
around. If you're tempted to teach the model that Apple Music catalog rows need a
vision click, that belongs in the music skill, not a new tool or a prompt line.

## How It Works

The model decides *what* to do and which tool to call; Swift decides *whether and
how* it runs, through permission grants and consent gates. Two execution surfaces
share one tool registry:

```
User turn
   │
   ▼
Fast command session  ── shell_exec, apps_list, app_skill, app_commands,
(always on, realtime)     skill_run, web_snapshot, llm.generate, web.search,
   │                      web.fetch
   │   can't finish it with the fast tools?
   ▼
agent_run  ──►  Desktop agent (full harness loop)
                adds GUI driving, AppleScript generate/validate/execute,
                skill search/load, app learning, verification, lifecycle
   │   app must be driven by sight?
   ▼
vision_control  ──►  vision agent operates the screen
```

The fast session answers most turns directly. It escalates only when it has to:
`agent_run` hands a multi-step or in-app-GUI task to the full harness loop, and
`vision_control` hands an app that can only be driven by sight to a vision agent.

## Tools the Fast Session Has

These are every tool the always-on realtime session can call. It reaches for them
roughly top-down — the lower entries are escalations, not defaults.

| Tool | Use it for |
|---|---|
| `shell_exec` | The primary, general tool: find files, launch/quit apps, read state, change settings, run `osascript` to drive an app's content. |
| `apps_list` | Get exact installed/running app names before targeting one. |
| `app_skill` | Look up an app's operating playbook before driving it. |
| `app_commands` | Read an app's real AppleScript vocabulary before generating any AppleScript for it. |
| `skill_run` | Execute a validated script a skill ships, instead of reinventing its steps. |
| `web_snapshot` | Render a page to a PDF or PNG file headlessly. |
| `web.search` | Search the web for current facts and get ranked results. |
| `web.fetch` | Read a page's main content as clean markdown. |
| `llm.generate` | Compose or transform text — a tracklist, a summary, a note body; set `toFile=true` for long output. |
| `agent_run` | Escalate multi-step work or in-app GUI work the fast tools can't complete. |
| `vision_control` | Escalate to operating an app by sight, when its skill says so or scripting failed. |

## Tools the Desktop Agent Adds

When `agent_run` hands a task to the full harness loop, the agent gets the fast
tools plus the harness-only tools below. The model never sees raw schemas in this
guide — each tool's parameters live in its descriptor in code.

**Conversation and lifecycle**

| Tool | Use it for |
|---|---|
| `conversation.respond` | Reply to the user when the turn needs an answer, not an action. |
| `user.clarify` | Ask one specific missing question and stop until it's answered. |
| `permission.request` | Ask for a missing runtime permission and stop until it's granted. |
| `memory.retrieve` | Pull task-relevant memory after intent is structured. |
| `run.pause` / `run.resume` / `run.recover` / `run.cancel` / `run.complete` / `run.failSafe` | Drive the task lifecycle — pause, resume, recover from a failed check, cancel, complete after evidence, or stop in a safe failed state. |

**Seeing and operating the screen**

| Tool | Use it for |
|---|---|
| `screen.observe` | Observe current screen and window state with screenshot and text evidence. |
| `elements.get` | List the actionable UI elements in scope, preferring Accessibility-backed ones. |
| `element.perform` | Perform a guarded action — press, set value, focus, scroll — on an element. |
| `text.enter` | Type exact text into the focused field. |
| `keyboard.press` | Press a validated key or shortcut. |
| `agent.path.visualize` | Prepare a visual-only pointer path from grounded evidence, performing no input. |

**AppleScript automation**

| Tool | Use it for |
|---|---|
| `automation.applescript.generate` | Generate a bounded AppleScript artifact for a resolved app task. |
| `automation.applescript.validate` | Compile and safety-check the artifact before any execution — wrong terminology is rejected here with the real compiler error. |
| `automation.applescript.execute` | Run a validated artifact through the guarded backend. |

**Skills**

| Tool | Use it for |
|---|---|
| `skill.search` | Search the skill registry by structured need when no specific app is targeted. |
| `skill.load` | Load a selected skill's instructions into planning context. |
| `skill.script.generate` | Generate a reusable script artifact inside a skill pack. |
| `skill.script.validate` | Validate or reject a generated skill script before any path can run it. |
| `skill.script.execute` | Execute a validated skill script through the guarded backend. |

**Learning a new app into a skill**

| Tool | Use it for |
|---|---|
| `application.learning.start` | Begin a skill-producing learning draft for a resolved app. |
| `application.learning.captureState` | Record a meaningful app state from screenshot, Accessibility, and navigation evidence. |
| `application.learning.proposeExploration` | Propose reversible exploration candidates and flag actions that need approval. |
| `application.learning.distill` | Distill captured states into an app profile and workflow recipes. |
| `application.learning.saveSkillPack` | Save the distilled profile as a reusable skill pack. |

**Files and verification**

| Tool | Use it for |
|---|---|
| `files.describe` | Understand a batch of files — kind, summary, extracted text, size — before acting on them. |
| `state.verify` | Confirm the expected outcome against world-model evidence and success criteria. |
| `wait` | Pause briefly while the UI settles, then re-plan. |

## The Execution Ladder

For any task, prefer the highest rung that can do it:

1. **Local first.** If an installed Mac app or system tool handles it, use that —
   never open a web service for something a local app does (play music in Music,
   not a web player).
2. **System tools via `shell_exec`.** Finding files, launching apps, reading
   state, and changing settings are shell work. The built-in system-tools skill
   is the authority on safe shell technique.
3. **A skill's validated script via `skill_run`.** When `app_skill` advertises a
   script that covers the task, run it rather than rebuilding the steps.
4. **AppleScript.** To read or change content inside a Mac app, drive it with
   `osascript`. Read its real vocabulary with `app_commands` first; never invent a
   URL scheme like `notes://` — those silently fail.
5. **Vision (`vision_control`).** Only when the app can't be scripted — its skill
   says vision, or scripting failed.
6. **The desktop agent (`agent_run`).** For multi-step work the fast tools can't
   finish.

The negative example: do not add a phrase list that maps "play some coldplay" to
the Music app. The model calls `app_skill` for the kind of app, the skill says
how to operate it, and `skill_run` does the task.

## Skills

A skill is a folder with a `SKILL.md` that teaches the agent how to operate one
app or capability the way an expert would. The model reads the body; the runtime
reads the frontmatter. Skills carry knowledge and may ship validated scripts —
they are not themselves tools. See [Authoring Skills](authoring-skills.md) for how
to write one.

Skills surface two ways, and the distinction is the whole point:

- **App skills** match on the *typed app identity* a turn targets — the display
  name or bundle id, compared token-wise so "Music" matches "Music.app" but not an
  unrelated app. Never matched against the user's words. The fast session looks
  one up with `app_skill`.
- **Other skills** carry no app and surface by lexical search over their tags and
  keywords for a workflow need (the shell, a browser, the web). The harness loop
  finds these by searching the skill registry.

A built-in always wins an id collision, so installing a skill can never shadow a
curated one.

### Built-in skills

| Skill | Covers |
|---|---|
| system-tools | Operating macOS like a power user — find files, launch/quit apps, read and change settings via shell. |
| browser | Opening websites in the default or a named browser. |
| safari | Driving Safari through AppleScript — open, read, and manage tabs. |
| finder | File management — shell for finding, Finder scripting for selection, reveal, and reversible trash. |
| notes | Creating, finding, and reading Apple Notes through AppleScript. |
| mail | Reading, searching, and composing in Apple Mail through AppleScript. |
| calendar | Reading and creating Calendar events through AppleScript over bounded date windows. |
| contacts | Looking up people in Apple Contacts — emails, phones, addresses. |
| reminders | Creating and reading Apple Reminders with due dates and alerts. |
| imessage | Sending iMessages through AppleScript, only after explicit confirmation. |
| music | Playing and controlling Apple Music natively through the playback tools. |
| spotify | Operating the Spotify desktop app by vision to search and play. |
| settings | Changing macOS settings via shell instead of clicking through System Settings. |
| numbers | Working with CSVs in shell first; driving Numbers via AppleScript to read and export. |
| documents | Working with PDFs and images in Preview via keyboard shortcuts and shell tools. |
| pdf | Headless PDF work — extract, merge, split, convert. |
| images | Still-image work — resize, convert, rotate, crop, composite. |
| media | Audio and video — download, transcode, trim. |
| data | Querying, reshaping, and converting CSV/JSON/TSV with shell tools. |
| weather | Low-risk weather lookups. |
| web-research | Finding current facts on the web and feeding them into notes or messages. |
| web-capture | Saving a web page to a file as markdown, PDF, or screenshot. |

## Safety Classes and Consent

Every tool declares a safety class. The safety class decides whether the action
runs immediately or stops for the user.

| Class | Behavior |
|---|---|
| read-only | Runs immediately; observation only (screen, web search, a read-only shell command). |
| reversible | Runs without confirmation — play, open, search, draft, navigate. |
| guarded input | Runs after one-time or always-allow consent — `shell_exec` that changes state, `skill_run`, GUI actions, AppleScript execution, `agent_run`, `vision_control`. |
| destructive | Asks every time — `sudo`, `rm`, deleting, anything irreversible. |
| sensitive | Model-boundary steps that produce an artifact but don't execute it — script generation, file description, text generation. |

Two invariants hold across all of them:

1. **Every input is guarded.** A tool that changes state, types, or clicks
   declares the permissions it needs; the registry refuses to run it until those
   permissions are granted, returning a permission-denied result the UI turns into
   a consent prompt.
2. **Reversible runs free, irreversible asks.** Low-risk reversible actions need
   no confirmation — just do them. Anything destructive, costly, or externally
   visible that goes beyond what the user explicitly asked for confirms first.

## Where It Lives

The fast command tools are defined in the command layer in the harness module;
the full harness catalog and the registry that gates execution sit alongside it;
the cross-tool doctrine that orders the ladder is in the agent prompts; and the
skills are folders under the runtime's built-in skills resources. Start with the
command layer to see the fast set, and [Authoring Skills](authoring-skills.md) to
extend it.
