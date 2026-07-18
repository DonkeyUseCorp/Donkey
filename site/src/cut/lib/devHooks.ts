"use client";

/**
 * Dev-only automation hooks: expose the Cut stores on window so a real-model
 * eval (a headless browser driving the actual pipeline) can start runs and
 * read progress deterministically instead of scraping the UI. Installed from
 * the editor root; a no-op in production builds.
 */

import { useGenerate } from "./generate";
import { useGenScene } from "./genScene";
import { enrichAsset, importFileToProject } from "./media";
import { useEditor } from "./store";

export function installDevHooks(): void {
  if (process.env.NODE_ENV === "production" || typeof window === "undefined") return;
  (window as unknown as Record<string, unknown>).__cutDev = {
    useEditor,
    useGenerate,
    useGenScene,
    importFileToProject,
    enrichAsset,
  };
}
