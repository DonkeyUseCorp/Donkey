"use client";

import { create } from "zustand";
import { apiFetch } from "./api";
import {
  cancelExportJob,
  createExportJob,
  downloadExport,
  type ExportDoc,
  type ExportSettings,
} from "./exportClient";

// Exports are tracked app-wide, not per-open-project. The engine holds every
// export job in one process-global registry, so this store is a thin reflection
// of that feed: every tab polls the same list and shows the same queue, and
// starting an export in one project while another still renders just adds a row.
// The dock (ExportsDock) renders it; the engine does the queueing.

export interface ExportJob {
  id: string;
  projectId: string;
  projectName?: string;
  status: "queued" | "running" | "done" | "error";
  progress: number; // 0..1
  outName?: string;
  error?: string;
  /** Epoch ms the encode began (elapsed clock) and the job was created (order). */
  startedAt?: number;
  createdAt?: number;
}

/** A client-only dock row for the brief window before the engine has a job id:
 * while the cut is being built and uploaded ("preparing"), or when that failed
 * before a job ever existed ("error"). Kept apart from the engine feed so a
 * poll tick never clears it. */
export interface LocalRow {
  id: string;
  projectId: string;
  projectName?: string;
  status: "preparing" | "error";
  error?: string;
  createdAt: number;
}

// Jobs this tab started, so this tab (and only this tab) auto-downloads them
// when they finish — the same one-download-per-export the single export gave.
// Other tabs still see the job and can download it by hand from the dock.
// Persisted in sessionStorage (per-tab, so it never crosses tabs) so a reload
// while an export is still rendering still auto-downloads the finished file on
// completion, the way the old per-project reconnect did.
const OWN_DOWNLOADS_KEY = "cut-own-exports";

function loadOwnDownloads(): Set<string> {
  try {
    const raw = sessionStorage.getItem(OWN_DOWNLOADS_KEY);
    return new Set(raw ? (JSON.parse(raw) as string[]) : []);
  } catch {
    return new Set();
  }
}

const ownDownloads = loadOwnDownloads();

function persistOwnDownloads() {
  try {
    sessionStorage.setItem(OWN_DOWNLOADS_KEY, JSON.stringify([...ownDownloads]));
  } catch {
    // Best-effort: without it, auto-download just won't survive a reload.
  }
}

function rememberOwnDownload(id: string) {
  ownDownloads.add(id);
  persistOwnDownloads();
}

function forgetOwnDownload(id: string) {
  ownDownloads.delete(id);
  persistOwnDownloads();
}

interface ExportsState {
  /** The engine's export feed, reflected verbatim on each poll. */
  jobs: ExportJob[];
  /** Rows that don't have an engine job yet (preparing / start error). */
  local: LocalRow[];
  /** Finished/failed engine jobs the user cleared from this tab's dock. */
  dismissed: string[];
  /** Build the cut and hand it to the engine; the dock tracks it from there. */
  start: (
    projectId: string,
    doc: ExportDoc,
    settings: ExportSettings,
    projectName?: string
  ) => Promise<void>;
  cancel: (id: string) => void;
  dismiss: (id: string) => void;
  /** Clear every finished/failed row at once; running work stays. */
  dismissSettled: () => void;
  /** One poll of the engine feed. */
  refresh: () => Promise<void>;
}

export const useExports = create<ExportsState>((set, get) => ({
  jobs: [],
  local: [],
  dismissed: [],

  start: async (projectId, doc, settings, projectName) => {
    const localId = `local-${crypto.randomUUID().slice(0, 8)}`;
    set((s) => ({
      local: [
        ...s.local,
        { id: localId, projectId, projectName, status: "preparing", createdAt: Date.now() },
      ],
    }));
    try {
      const jobId = await createExportJob(projectId, doc, settings);
      rememberOwnDownload(jobId);
      set((s) => ({ local: s.local.filter((r) => r.id !== localId) }));
      void get().refresh(); // show the queued job now, not on the next tick
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      set((s) => ({
        local: s.local.map((r) =>
          r.id === localId ? { ...r, status: "error", error: msg } : r
        ),
      }));
    }
  },

  cancel: (id) => {
    cancelExportJob(id);
    forgetOwnDownload(id);
    set((s) => ({
      jobs: s.jobs.map((j) =>
        j.id === id ? { ...j, status: "error", error: "Export canceled." } : j
      ),
    }));
    void get().refresh();
  },

  dismiss: (id) =>
    set((s) => ({
      local: s.local.filter((r) => r.id !== id),
      dismissed: s.jobs.some((j) => j.id === id)
        ? [...new Set([...s.dismissed, id])]
        : s.dismissed,
    })),

  dismissSettled: () =>
    set((s) => ({
      local: s.local.filter((r) => r.status !== "error"),
      dismissed: [
        ...new Set([
          ...s.dismissed,
          ...s.jobs
            .filter((j) => j.status === "done" || j.status === "error")
            .map((j) => j.id),
        ]),
      ],
    })),

  refresh: async () => {
    let list: ExportJob[];
    try {
      const res = await apiFetch("/api/cut/export-jobs");
      if (!res.ok) return; // engine hiccup — keep the last good view
      list = (await res.json()) as ExportJob[];
    } catch {
      return;
    }
    for (const j of list) {
      const settled = j.status === "done" || j.status === "error";
      if (j.status === "done" && j.outName && ownDownloads.has(j.id)) {
        downloadExport(j.id, j.outName);
      }
      if (settled) forgetOwnDownload(j.id);
    }
    set((s) => ({
      jobs: list,
      dismissed: s.dismissed.filter((id) => list.some((j) => j.id === id)),
    }));
  },
}));

// The dock is mounted app-wide, so polling runs the whole time the Cut app is
// open. It quickens while work is in flight and idles between exports.
let pollTimer: ReturnType<typeof setTimeout> | null = null;
let mounts = 0;

export function beginExportPolling() {
  mounts++;
  if (pollTimer !== null) return;
  const tick = async () => {
    await useExports.getState().refresh();
    if (mounts === 0) {
      pollTimer = null;
      return;
    }
    const s = useExports.getState();
    const active =
      s.local.length > 0 ||
      s.jobs.some((j) => j.status === "queued" || j.status === "running");
    pollTimer = setTimeout(tick, active ? 700 : 3000);
  };
  pollTimer = setTimeout(tick, 0);
}

export function endExportPolling() {
  mounts = Math.max(0, mounts - 1);
  if (mounts === 0 && pollTimer !== null) {
    clearTimeout(pollTimer);
    pollTimer = null;
  }
}
