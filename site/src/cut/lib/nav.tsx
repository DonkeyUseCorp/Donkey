"use client";

import { createContext, useContext, type ReactNode } from "react";

// The Cut app's routes live under /cut/*. On the cut.* production host a proxy
// rewrite (src/proxy.ts) serves them at the root, so links are root-relative
// (base ""). In local dev the app is served from the apex under /cut so its
// session cookie is same-origin, and links carry the "/cut" base. The base is
// resolved on the server from the request host (see the cut layout) and handed
// to the client here.
const CutBaseContext = createContext("");

export function CutBaseProvider({ base, children }: { base: string; children: ReactNode }) {
  return <CutBaseContext.Provider value={base}>{children}</CutBaseContext.Provider>;
}

export function useCutBase(): string {
  return useContext(CutBaseContext);
}

// The project editor can be reached from either home tab, from inside a
// folder or not. The origin rides along in the project URL (?from=… and
// ?folder=…) so the editor's back button returns to the exact place the
// project was opened from — Projects, Library, or a folder within one. The
// home pages read ?folder=… as the open folder, which also lets the browser's
// own back button step folder → root.
export type CutTab = "projects" | "library";

/** Which home tab a pathname is on (base-agnostic). */
export function tabForPath(pathname: string): CutTab {
  return pathname.endsWith("/library") ? "library" : "projects";
}

/** Home tab URL under the given base, optionally inside a folder. Projects is
 * the base root. */
export function homeHref(base: string, tab: CutTab, folder?: string | null): string {
  const root = tab === "library" ? `${base}/library` : base || "/";
  return folder ? `${root}?folder=${encodeURIComponent(folder)}` : root;
}

/** Project editor URL that remembers the tab (and folder, when open) it was
 * opened from. The default origin carries no query so the common URL stays
 * clean. */
export function projectHref(
  base: string,
  id: string,
  from: CutTab,
  folder?: string | null
): string {
  const params = new URLSearchParams();
  if (from === "library") params.set("from", "library");
  if (folder) params.set("folder", folder);
  const qs = params.toString();
  return `${base}/p/${id}${qs ? `?${qs}` : ""}`;
}

/** Where the editor's back button goes, and the tab it is named for. An unknown
 * origin falls back to Projects. */
export function backTarget(
  base: string,
  from: string | null | undefined,
  folder?: string | null
): { href: string; tab: CutTab } {
  const tab: CutTab = from === "library" ? "library" : "projects";
  return { href: homeHref(base, tab, folder), tab };
}
