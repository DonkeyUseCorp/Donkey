# Engineering Doc Style Guide

For internal architecture docs, runtime specs, and contributor guides — anything
a teammate (or a coding agent) will read once and then follow precisely.

## Core Principles

**1. Lead with the point.**
The first paragraph answers "what is this and why does it exist" in plain
words. No throat-clearing, no history. If the doc has one governing rule,
state it by the second paragraph and label it (`**The one rule:**`). Readers
should be able to stop after the intro and still behave correctly.

**2. Say each thing exactly once.**
One canonical explanation per concept, in the place readers will look for it.
Everything else references it ("see the loop above") instead of restating it.
If you find the same idea in two sections, one of them is the home and the
other becomes a pointer.

**3. Diagrams are the source of truth, prose is the commentary.**
A loop, pipeline, or lifecycle gets one ASCII diagram — numbered steps if order
matters. Prose around it explains *why*, never re-narrates *what*. Never draw
the same flow twice.

**4. Name the division of labor in one sentence.**
When two components share responsibility, compress it to a contrast:
"The model decides *what*; Swift decides *whether and how*." A reader who
remembers only that sentence still makes correct decisions.

**5. Rules become tables; stories stay prose.**
Anything that is a lookup — states and their outcomes, risk tiers and their
behaviors, file types and what's read from each — goes in a table. Prose is for
reasoning and intent; tables are for facts you check against.

**6. State invariants as numbered, named rules.**
Don't smear a constraint across four paragraphs. Extract it:

> 1. **Every input is guarded.** …
> 2. **Done means evidence.** …

Bold name first, consequence after. The bold name becomes the vocabulary the
team uses in review comments.

**7. Show the negative example.**
The fastest way to make a rule concrete is to show the violation:
"If you're tempted to write `if command.contains(\"music\")`, the logic belongs
in a skill." One forbidden snippet teaches more than a paragraph of abstraction.

**8. Prefer the concrete word, in plain English.**
"The model proposes a name and a protected command applies it" beats "the
generator emits a candidate the executor commits." Be concrete about what
happens, but say it in plain words — not by naming internal tools, types, or
file paths, which read as jargon and churn on every refactor.

## Sentence-Level Rules

- **Imperative or declarative, never hedged.** "Adapters never hold task
  state," not "adapters should generally avoid holding task state."
- **Short sentences carry rules; longer sentences carry rationale.** A rule
  over ~20 words is probably two rules.
- **Active voice with a named actor.** "The planner picks the tool," not "the
  tool is selected."
- **Bold sparingly, and only for rule names and key contrasts.** If half a
  paragraph is bold, nothing is.
- **Italics only for word-level contrast** (*what* vs *whether*), never for
  emphasis-shouting.
- **State what a thing is; don't negate a foil nobody proposed.** Write "The
  safety class decides whether the action stops for the user," not "The class,
  *not the tool's name*, decides…" The appended opposite ("X, not Y," "it's not
  Z, it's W") reads as defensive and machine-written. This is different from the
  division-of-labor contrast in Principle 4, which assigns real work to two real
  actors ("the model decides *what*; Swift decides *whether*"); the foil is bad
  only when Y is a strawman the reader never would have assumed.
- **Code font only for what a reader will actually type or run** — a real
  command or flag. Don't set internal tool names, types, states, or paths in
  backticks just because they exist in the code; describe what they do in plain
  English instead.

## Structure Template

```text
# Title

What this is + why it exists (2–4 sentences).
**The one rule:** the governing constraint, with a negative example.

## How It Works        — the canonical diagram + the division-of-labor sentence
## [Core nouns]        — one section per major concept (state, boundaries, tools)
## [Hard constraints]  — invariants as numbered named rules, lookups as tables
## Where it lives      — one short sentence naming the area to start in
```

Sections are nouns ("Task State," "Model Boundary"), not gerunds ("Managing
Task State"). Order by what a new reader needs first, ending with a short
pointer to where the code lives so the doc lands on "where to go next." That
pointer is prose, not a catalog: name the area, skip the exact paths, class
names, and test names — they churn and the reader can grep.

## What to Cut

- Restatements ("as mentioned above," "in other words")
- Adjectives that don't change behavior ("robust," "powerful," "seamless")
- Anticipatory caveats for situations no reader is in
- Meta-commentary about the doc itself ("this section describes…")
- Anything a table header already says
- Code symbols and jargon when plain English works. Internal tool names, type
  names, file paths, and coined compound terms ("reversible-write consent")
  churn and read as jargon — describe what the thing does instead. Keep a symbol
  or exact command only when a reader genuinely must type or grep it.
- Catalogs that churn. No Source Map tables, no file-path lists, no test-name
  lists, no exact line numbers. Point with one short sentence naming the area to
  start in, and only when it helps.

## The Test

After writing, ask three questions:

1. Could a reader stop at the end of the intro and still avoid the worst
   mistakes? (If no — the governing rule is buried.)
2. Is any concept explained twice? (If yes — pick the home, delete the rest.)
3. Could a coding agent follow this doc without asking clarifying questions?
   (If no — a rule is hedged, an example is missing, or a lookup isn't a
   table.)
