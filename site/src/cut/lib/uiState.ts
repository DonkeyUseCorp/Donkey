"use client";

/**
 * Per-project view state (zoom level, timeline panel height) — how this
 * browser looks at a project, not part of the cut. Stored in IndexedDB
 * keyed by project id; project.json only carries real content.
 */
export interface ProjectUiState {
  pxPerSec?: number;
  timelineH?: number;
}

const DB_NAME = "cut";
const STORE = "project-ui";

function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => {
      if (!req.result.objectStoreNames.contains(STORE)) req.result.createObjectStore(STORE);
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

export async function loadUiState(projectId: string): Promise<ProjectUiState> {
  try {
    const db = await openDb();
    return await new Promise((resolve) => {
      const req = db.transaction(STORE).objectStore(STORE).get(projectId);
      req.onsuccess = () => resolve((req.result as ProjectUiState) ?? {});
      req.onerror = () => resolve({});
    });
  } catch {
    return {}; // e.g. private-mode quota — fall back to defaults
  }
}

// Writes are debounced and merged so slider drags don't hammer the store.
let pending: { projectId: string; patch: ProjectUiState } | null = null;
let timer: ReturnType<typeof setTimeout> | null = null;

async function flush() {
  const job = pending;
  pending = null;
  if (!job) return;
  try {
    const db = await openDb();
    const tx = db.transaction(STORE, "readwrite");
    const store = tx.objectStore(STORE);
    const req = store.get(job.projectId);
    req.onsuccess = () =>
      store.put({ ...((req.result as ProjectUiState) ?? {}), ...job.patch }, job.projectId);
  } catch {
    // View state is best-effort; losing it only resets zoom/height defaults.
  }
}

export function saveUiState(projectId: string, patch: ProjectUiState) {
  if (pending && pending.projectId !== projectId) void flush();
  pending = { projectId, patch: { ...(pending?.patch ?? {}), ...patch } };
  if (timer) clearTimeout(timer);
  timer = setTimeout(() => void flush(), 300);
}
