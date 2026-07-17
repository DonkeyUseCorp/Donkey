"use client";

/**
 * The run's live ticker — one line narrating what is happening right now,
 * updated constantly ("Drawing pose 3/6…", "Binding 6 poses into a clip…").
 * Adapters report fire-and-forget; whoever renders the run subscribes. Latest
 * message wins — this is a status line, not a log. The orchestrator itself
 * stays browser-free and narrates through its typed `activity` event instead;
 * both streams converge in the scene store.
 */

type Listener = (message: string, projectId?: string) => void;
const listeners = new Set<Listener>();

/** `projectId` scopes the line to one run — with several projects rendering
 * at once, a background run must not narrate over the open one's card. */
export function reportActivity(message: string, projectId?: string): void {
  for (const fn of listeners) fn(message, projectId);
}

export function onActivity(fn: Listener): () => void {
  listeners.add(fn);
  return () => {
    listeners.delete(fn);
  };
}
