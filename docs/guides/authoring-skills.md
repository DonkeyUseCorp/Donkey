# Authoring Skills

A skill is a folder with a `SKILL.md` that teaches the agent how to do
something the way an expert would. The model reads the body; deterministic code
reads the frontmatter.

**The one rule:** app-specific operating knowledge lives in skills, never in
prompts or core runtime code. If you're tempted to teach
`DonkeyPrompts.swift` that Apple Music catalog rows need vision clicks, write
that in `BuiltInSkills/music/SKILL.md` instead.

## Prompt vs Skill

Generic cross-app doctrine lives in the global prompts (`DonkeyPrompts.swift`):
act directly on low-risk reversible actions, confirm destructive or externally
visible ones, prefer scripts before GUI, verify before claiming success, never
retry blindly, keep responses short. A skill never restates those rules — it
states the app-specific version of them.

- Bad (generic, already in the prompt): "Always verify before claiming success."
- Good (app-specific): "Music can report `player state=playing` while nothing
  is loaded — verify `player position` advances."

## Skill Kinds

| Kind | Identified by | Surfaces when |
|---|---|---|
| App skill | `apps:` line listing display names + bundle ids | a turn targets that app — matched on the typed app identity, never the user's words |
| Other skill | no `apps:` line; `tags`/`keywords` | lexical search finds it for a workflow need |

Name an app skill after its app (`notes`, `mail`, `music`). Name an other
skill after its capability (`system-tools` for the shell, `browser` for any
browser, `weather`).

## Locations

Built-in skills live in
`apps/Donkey/Sources/DonkeyRuntime/Resources/BuiltInSkills/<id>/SKILL.md`.
Learned skills are written to the app-support learned directory and discovered
the same way. The folder name is the skill id; keep it the clean app or
capability name (`music`), not a description
(`play-music-in-apple-music-with-search`).

## Frontmatter

Lines the discovery parser reads, near the top of the file (everything else is
the playbook body):

```text
# Notes                      <- heading becomes the display name
id: notes                    <- defaults to the folder name
description: One line; used for ranking in search.
tags: notes, writing         <- comma-separated
keywords: note, save, jot    <- natural trigger words for lexical search
apps: Notes, com.apple.Notes <- APP SKILLS ONLY: display names + bundle ids
tools: shell_exec, skill_run <- tools the skill expects to use
```

## Body

Write the operating playbook as an expert would brief a teammate. Cover, in
roughly this order:

1. What the skill is for, and what it does directly vs confirms first
2. Preferred execution path — validated script or exact AppleScript
3. Bounded fallback path
4. Verification — the app-specific success check
5. Known limitations
6. Failure behavior and response style

A reader should come away knowing what to do first, what never to do, how to
verify success, the app's quirks, when to stop retrying, and what to tell the
user.

Three kinds of app-specific facts deserve explicit statements:

- **Where the app breaks the execution ladder.** The generic preference is
  validated script (`skill_run`) → app scripting (`shell_exec` + `osascript`)
  → Accessibility → vision. When the app deviates, say so: "catalog rows are
  not in the AX tree — do not retry AX clicks, use vision once."
- **Confirmation boundaries.** Creating a local note is low-risk; sending mail
  or inviting external attendees is externally visible and asks first. State
  the skill's own line.
- **Bounded fallbacks.** When to fall back, which tool, how many attempts, and
  how to report failure. Never "try other methods until it works."

## Compactness

Several skills can load in the same turn, so every line costs context.
Built-in packs run 11–75 lines (`music`, the fullest, is 75). Prefer short
rules, exact commands, known pitfalls, and script statuses; cut long examples,
edge-case inventories, and anything the global prompt already says. If a
section keeps growing, the content probably belongs in a validated script or a
separate capability skill.

Keep commands single-line, copyable, and parenthesis-free where possible (see
`system-tools`). If user text can carry apostrophes, quotes, or newlines, do
not hand-build shell quoting around it — move the logic into a validated
script that takes raw input safely.

## Scripts

A skill may ship validated scripts in a `scripts/` subfolder — discovery picks
them up automatically, with no frontmatter line. The script id is the slugged
relative path without extension
(`scripts/play-media-by-search.applescript` → `scripts-play-media-by-search`).
AppleScript, shell, and JavaScript files are recognized; bundled scripts count
as validated, learned ones start as pending validation.

The agent runs scripts with `skill_run` instead of reinventing the steps, so
the body documents each one: id, expected input, what it does, the statuses it
returns, and what to do for each status — including whether fallback is
allowed:

```text
`skill_run` with `scriptID=scripts-play-media-by-search`, input = the
normalized query. `status=played` → verified, report what's playing.
`status=not_found` → read `hint=`; do not rerun the same query.
```

Scripts are bounded and deterministic: one search-and-play, one note created,
one export. No open-ended browsing, retry loops, or unbounded polling.

See existing packs under `BuiltInSkills/` for the shape — `music` is the
fullest example (script statuses, an AX limitation, verification, failure
behavior); `notes` and `mail` are simpler app skills; `system-tools` is an
other-skill.
