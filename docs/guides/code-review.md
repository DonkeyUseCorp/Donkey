# Code Review Guide

## Purpose

We review code so the next person can read it. A change is good when a teammate
can open the file, follow the logic top to bottom, and understand why it is
correct without chasing it across the codebase. This guide is what we look for.
It applies to Swift (`apps/Donkey`) and TypeScript (`site`) alike.

The goal of every change is to reduce the total complexity a reader has to hold
in their head. Adding code that does this is progress. Adding code that hides
complexity behind more moving parts is not, even when each piece looks small.

## Prefer Deep Functions, Not Shallow Ones

A function earns its name by hiding real work behind a simple interface. A deep
function takes a small, obvious input and saves the caller from a lot of detail.
A shallow function adds a name and a call frame but hides almost nothing.

- Do not wrap a single call or a one-line expression in a new function just to
  give it a name. Inline it; the reader can see what it does.
- Do not split a coherent piece of logic into a chain of tiny helpers that each
  do one trivial step. Following the chain costs more than reading the whole.
- Do split when a block has a genuine, nameable responsibility with a narrow
  interface, when it is reused, or when the detail it hides is real.
- Judge an interface by how much it lets the caller forget, not by line count.

When you are tempted to extract, ask: does the caller become simpler to read,
or does it just gain another name to follow? Extract only for the former.

## Keep Indirection to a Minimum

Every layer the reader must step through to find the real behavior is a tax.
Pay it only when it buys something.

- Prefer a direct call to a small ladder of pass-through wrappers, adapters, and
  re-exports that only forward arguments.
- Do not add an interface, protocol, or injection seam for a single
  implementation that has no second caller and no test that needs to fake it.
- Avoid barrel/`index.ts` re-exports and broad protocol indirection that exist
  only to look layered. Import the concrete thing directly.
- A reader should reach the code that does the work in one or two hops, not five.

Indirection that maps to a real boundary is good: the Swift MVC split
(`docs/guides/swift-mvc.md`) and the typed harness/model boundaries
(`docs/guides/agent-harness.md`) exist for reasons. The tax is forwarding layers
that exist for their own sake.

## Simplify the Design

- Solve the problem in front of you. Do not add configuration, generality, or
  extension points for a future that has not arrived.
- Remove derivable or duplicated state. If a value can be computed from another,
  compute it; do not store and sync two copies.
- Collapse special cases into the shared mechanism instead of bolting another
  branch onto it. A growing pile of special cases usually means the underlying
  design needs to change, not that it needs one more `if`.
- Build forward. Update callers to the new shape rather than keeping
  compatibility shims and dead branches. Ask before keeping a shim.
- Delete code the change makes unreachable. Do not leave it commented out.

## Write For Human Readers

- Names should carry the meaning. A reader who knows only the name should guess
  the behavior. Rename before you comment around a confusing name.
- Comments explain *why* — the constraint, the edge case, the reason this is not
  the obvious approach. Do not narrate *what* the code already says.
- Keep nesting shallow. Return early, handle the error case first, and let the
  main path run down the left margin.
- Keep the happy path obvious and the rare path out of its way.
- Match the surrounding code's idiom, naming, and comment density. A change that
  reads like the file around it is easier to trust.

## Repo-Specific Rules

- Never infer user intent by matching raw input text. No phrase lists, prefixes,
  regexes, or app-name checks to decide what the user wants. Route the turn
  through an LLM or a typed model boundary, then match on structured output
  only. See `docs/guides/agent-harness.md`.
- Keep the Swift MVC boundaries intact: views render and emit intents, models
  own state, controllers own AppKit. See `docs/guides/swift-mvc.md`.
- For `site`, follow `docs/guides/frontend-nextjs-guidelines.md`: server
  components by default, no `fetch` from components, no `any`.
- Never commit secrets, keys, tokens, or PII. This repo is open source.

## Review Checklist

- Does each new function hide enough to justify its interface, or is it shallow?
- Can the reader reach the real work in one or two hops?
- Is there state that could be derived instead of stored and kept in sync?
- Is a new special case hiding a design that should be generalized instead?
- Does a name need a comment to be understood? Rename it.
- Is there a compatibility shim or dead branch that should be removed instead?
- Does any code decide semantic intent by matching raw user text?
- Does the change read like the code around it?
