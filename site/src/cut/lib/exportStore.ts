"use client";

import { create } from "zustand";
import { apiFetch } from "./api";
import {
  downloadExport,
  pollExport,
  startExport,
  type ExportDoc,
  type ExportHandle,
  type ExportSettings,
} from "./exportClient";

// The current export, held outside the dialog so it keeps running (and stays
// visible) after the dialog closes. One export at a time is plenty here.

type Status = "idle" | "running" | "done" | "error";

interface ExportState {
  status: Status;
  stage: string;
  ratio: number;
  outName?: string;
  error?: string;
  projectId: string | null;
  handle: ExportHandle | null;
  start: (projectId: string, doc: ExportDoc, settings: ExportSettings) => void;
  cancel: () => void;
  dismiss: () => void;
  /** After a reopen or reload, rejoin an export still running for a project. */
  reconnect: (projectId: string) => Promise<void>;
}

export const useExport = create<ExportState>((set, get) => ({
  status: "idle",
  stage: "",
  ratio: 0,
  projectId: null,
  handle: null,

  start: (projectId, doc, settings) => {
    get().handle?.cancel();
    set({
      status: "running",
      stage: "Preparing",
      ratio: 0,
      error: undefined,
      outName: undefined,
      projectId,
    });
    const handle = startExport(projectId, doc, settings, (stage, ratio) => set({ stage, ratio }));
    set({ handle });
    handle.done
      .then(({ outName }) => set({ status: "done", outName, ratio: 1, handle: null }))
      .catch((err: unknown) =>
        set({
          status: "error",
          error: err instanceof Error ? err.message : String(err),
          handle: null,
        })
      );
  },

  cancel: () => {
    get().handle?.cancel();
    set({ status: "idle", handle: null, ratio: 0, stage: "" });
  },

  dismiss: () =>
    set({ status: "idle", ratio: 0, stage: "", error: undefined, outName: undefined }),

  reconnect: async (projectId) => {
    if (get().status === "running") return;
    const list = (await apiFetch(`/api/cut/projects/${projectId}/export-jobs`)
      .then((r) => (r.ok ? r.json() : []))
      .catch(() => [])) as { id: string; status: string; progress: number; outName?: string }[];
    const running = list.find((j) => j.status === "running");
    if (!running) return;
    set({ status: "running", stage: "Rendering", ratio: running.progress, projectId });
    pollExport(running.id, (stage, ratio) => set({ stage, ratio }))
      .then((outName) => {
        downloadExport(running.id, outName);
        set({ status: "done", outName, ratio: 1 });
      })
      .catch((err: unknown) =>
        set({ status: "error", error: err instanceof Error ? err.message : String(err) })
      );
  },
}));
