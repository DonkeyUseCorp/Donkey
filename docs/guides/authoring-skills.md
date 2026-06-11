# Authoring Skills

A skill is a folder with a `SKILL.md` that teaches the agent how to do
something the way an expert would. The model reads the body; deterministic code
reads the frontmatter.

**The one rule:** app-specific operating knowledge lives in skills, never in
prompts or core runtime code. If you're tempted to teach the harness about
Notes inside `DonkeyPrompts.swift`, write
`BuiltInSkills/notes/SKILL.md` instead.

## Skill Kinds

| Kind | Identified by | Surfaces when |
|---|---|---|
| App skill | `apps:` line listing display names + bundle ids | a turn targets that app — matched on the typed app identity, never the user's words |
| Other skill | no `apps:` line; `tags`/`keywords` | lexical search finds it for a workflow need |

Name an app skill after its app (`notes`, `mail`). Name an other skill after
its capability (`system-tools` for the shell, `browser` for any browser,
`weather`).

## Locations

Built-in skills live in
`apps/Donkey/Sources/DonkeyRuntime/Resources/BuiltInSkills/<id>/SKILL.md`.
Learned skills are written to the app-support learned directory and discovered
the same way. The folder name is the skill id; keep it the clean app or
capability name, not a description.

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
way to do the common tasks, the exact commands or AppleScript, the pitfalls,
and how to verify. Prefer `shell_exec` with `osascript` over driving the GUI;
reach for vision only when scripting can't. Keep commands single-line and
parenthesis-free where possible (see `system-tools`). State boundaries — what
must ask the user first (sending, deleting, purchases).

## Scripts

A skill may ship validated scripts in a `scripts/` subfolder — discovery picks
them up automatically, with no frontmatter line. The agent runs them with
`skill_run` instead of reinventing the steps, so name and reference them in
the body. Scripts must be bounded and deterministic.

See existing packs under `BuiltInSkills/` for the shape — `notes` and `mail`
for app skills, `system-tools` for an other-skill.
