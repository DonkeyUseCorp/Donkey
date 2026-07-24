// Chat history is per project. localStorage is the synchronous mirror every
// reader uses; in cloud mode the server keeps the account copy, and this
// module owns the sync between the two (pull on project open, debounced push
// per thread). It lives below the AI panel — which owns the history — and the
// generate store — which must refuse to resume a render whose thread the user
// deleted — so the two can reach it without importing each other.
import { apiFetch, cutMode } from "./backend";

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
 * project itself is deleted, so no stale thread or its renders survive it.
 * Server rows go with the project (the cloud delete cascades them). */
export function clearProjectThreads(projectId: string): void {
  try {
    localStorage.removeItem(threadsKey(projectId));
    localStorage.removeItem(activeChatKey(projectId));
  } catch {
    // Storage blocked — nothing to clear.
  }
}

// ---- Cloud sync -------------------------------------------------------------
// The panel stores threads slimmed (frame payloads stripped), so the pushed
// copy is exactly the mirrored one. Every call below is a no-op in local mode.

/** The wire shape of one saved thread; the panel's ChatThread narrows it. */
export interface StoredChatThread {
  id: string;
  title: string;
  updatedAt: number;
  messages: unknown[];
  sessions: Record<string, string>;
}

const chatPath = (projectId: string, chatId?: string) =>
  `/api/cut/projects/${encodeURIComponent(projectId)}/chats` +
  (chatId ? `/${encodeURIComponent(chatId)}` : "");

// One debounced PUT per thread: the panel saves on every streamed chunk, and
// the trailing edge (plus the next turn's saves) keeps the server copy close
// without a request per token.
const PUSH_DEBOUNCE_MS = 1000;
const pushTimers = new Map<string, ReturnType<typeof setTimeout>>();
// Projects with a push still queued or in flight; a pull that landed mid-write
// must not clobber the newer local mirror with the server's older copy.
const dirtyProjects = new Map<string, number>();

const markDirty = (projectId: string) =>
  dirtyProjects.set(projectId, (dirtyProjects.get(projectId) ?? 0) + 1);
const clearDirty = (projectId: string) => {
  const n = (dirtyProjects.get(projectId) ?? 1) - 1;
  if (n <= 0) dirtyProjects.delete(projectId);
  else dirtyProjects.set(projectId, n);
};

/** Queue the server copy of one thread (cloud mode only). */
export function pushThread(projectId: string, thread: StoredChatThread): void {
  if (cutMode() !== "cloud") return;
  const key = `${projectId}/${thread.id}`;
  const pending = pushTimers.get(key);
  if (pending) clearTimeout(pending);
  else markDirty(projectId);
  pushTimers.set(
    key,
    setTimeout(() => {
      pushTimers.delete(key);
      void apiFetch(chatPath(projectId, thread.id), {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(thread),
      })
        .catch(() => {
          // Offline — the mirror still has it; the next turn's push retries.
        })
        .finally(() => clearDirty(projectId));
    }, PUSH_DEBOUNCE_MS),
  );
}

/** Delete a thread's server copy (cloud mode only). */
export function pushThreadDelete(projectId: string, threadId: string): void {
  if (cutMode() !== "cloud") return;
  const key = `${projectId}/${threadId}`;
  const pending = pushTimers.get(key);
  if (pending) {
    clearTimeout(pending);
    pushTimers.delete(key);
    clearDirty(projectId);
  }
  void apiFetch(chatPath(projectId, threadId), { method: "DELETE" }).catch(() => {
    // Offline — the project-scoped rows are also cleaned when the project goes.
  });
}

const syncs = new Map<string, Promise<void>>();

/** Pull the account's threads into the local mirror (cloud mode only).
 * Callers await it before the first mirror read so a chat started on another
 * browser resumes here; concurrent calls share one fetch. Failures resolve —
 * the mirror keeps serving whatever it has. */
export function syncProjectThreads(projectId: string): Promise<void> {
  if (cutMode() !== "cloud") return Promise.resolve();
  let p = syncs.get(projectId);
  if (p) return p;
  p = (async () => {
    try {
      const res = await apiFetch(chatPath(projectId));
      if (!res.ok) return;
      const list = (await res.json()) as unknown;
      if (!Array.isArray(list)) return;
      // A local write raced the pull; its push is newer than what we fetched.
      if (dirtyProjects.has(projectId)) return;
      localStorage.setItem(threadsKey(projectId), JSON.stringify(list));
    } catch {
      // Offline or blocked — the mirror keeps serving.
    } finally {
      syncs.delete(projectId);
    }
  })();
  syncs.set(projectId, p);
  return p;
}
