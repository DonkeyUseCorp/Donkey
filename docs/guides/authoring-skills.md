# Authoring Skills

A skill is a folder with a `SKILL.md` that teaches the agent how to do something
the way an expert would. The model reads the body; deterministic code reads the
frontmatter. App-specific operating knowledge belongs here, never in prompts.

Built-in skills live in
`apps/Donkey/Sources/DonkeyRuntime/Resources/BuiltInSkills/<id>/SKILL.md`.
Learned skills are written to the app-support learned directory and discovered
the same way. The folder name is the skill id; keep it the clean app or
capability name (`notes`, `mail`, `system-tools`), not a description.

## Two kinds of skill

**App skills** operate one Mac app. They carry an `apps:` line listing the app's
display names and bundle ids. That line is how the runtime auto-matches and
preloads the skill when a turn targets that app — match is on the typed app
identity, never on the user's words. Name the skill after the app.

**Other skills** are capabilities not tied to a single app (`system-tools` for
the shell, `browser` for any browser, `weather`). They omit `apps:` and surface
through search on their `tags`/`keywords` when a workflow needs them.

## Frontmatter

Lines the discovery parser reads (everything else is the playbook body):

```text
# Notes                      <- heading becomes the display name
id: notes                    <- defaults to the folder name
description: One line; used for ranking in search.
tags: notes, writing         <- comma-separated
keywords: note, save, jot    <- natural trigger words for lexical search
apps: Notes, com.apple.Notes <- APP SKILLS ONLY: display names + bundle ids
tools: shell_exec, app_skill <- tools the skill expects to use
```

## Body

Write the operating playbook as an expert would brief a teammate: the reliable
way to do the common tasks, the exact commands or AppleScript, the pitfalls, and
how to verify. Prefer `shell_exec` with `osascript` over driving the GUI; reach
for vision only when scripting can't. Keep commands single-line and
parenthesis-free where possible (see `system-tools`). State boundaries — what
must ask the user first (sending, deleting, purchases).

## Scripts

A skill may ship validated scripts in a `scripts/` subfolder — discovery picks
them up from there automatically (no frontmatter line needed). The agent runs
them with `skill_run` instead of reinventing the steps, so name and reference
them in the body. Scripts must be bounded and deterministic.

See existing packs under `BuiltInSkills/` for the shape — `notes` and `mail` for
app skills, `system-tools` for an other-skill.
