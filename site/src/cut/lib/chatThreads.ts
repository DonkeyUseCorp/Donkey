// Chat history is per project, stored in localStorage. The keys and a couple of
// raw readers live in this leaf module (importing nothing app-specific) so both
// the AI panel — which owns the history — and the generate store — which must
// refuse to resume a render whose thread the user deleted — can reach it without
// importing each other.

// The keys derive from the route's project id, never the editor store's
// projectId (that still points at the previously open project until loadProject
// lands, which used to leak one project's chat into another).
export const threadsKey = (projectId: string) => `cut-ai-threads-${projectId}`;
// The open chat survives hiding the panel — only the + button starts a new one.
export const activeChatKey = (projectId: string) => `cut-ai-active-${projectId}`;

/** The ids of every saved thread in a project. The render-resume guard checks a
 * job's owning thread against this on boot: a chat render whose thread is gone
 * (deleted, or its whole project deleted, which clears these keys) is dismissed
 * rather than landed, so a reload can't resurrect media the user removed. */
export function readThreadIds(projectId: string): Set<string> {
  try {
    const v = JSON.parse(localStorage.getItem(threadsKey(projectId)) ?? "[]") as unknown;
    if (!Array.isArray(v)) return new Set();
    return new Set(
      v.map((t) => (t as { id?: unknown }).id).filter((x): x is string => typeof x === "string")
    );
  } catch {
    return new Set();
  }
}

/** Drop a project's chat history and active-thread pointer — called when the
 * project itself is deleted, so no stale thread or its renders survive it. */
export function clearProjectThreads(projectId: string): void {
  try {
    localStorage.removeItem(threadsKey(projectId));
    localStorage.removeItem(activeChatKey(projectId));
  } catch {
    // Storage blocked — nothing to clear.
  }
}
