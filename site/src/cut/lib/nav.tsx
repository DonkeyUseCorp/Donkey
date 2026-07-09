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

// The project editor can be reached from either home tab. The origin tab rides
// along in the project URL (?from=…) so the editor's back button returns to the
// tab you opened the project from — Projects or Library.
export type CutTab = "projects" | "library";

/** Which home tab a pathname is on (base-agnostic). */
export function tabForPath(pathname: string): CutTab {
  return pathname.endsWith("/library") ? "library" : "projects";
}

/** Home tab URL under the given base. Projects is the base root. */
export function homeHref(base: string, tab: CutTab): string {
  return tab === "library" ? `${base}/library` : base || "/";
}

/** Project editor URL that remembers the tab it was opened from. The default
 * tab carries no query so the common URL stays clean. */
export function projectHref(base: string, id: string, from: CutTab): string {
  return from === "library" ? `${base}/p/${id}?from=library` : `${base}/p/${id}`;
}

/** Where the editor's back button goes, and the tab it is named for. An unknown
 * origin falls back to Projects. */
export function backTarget(
  base: string,
  from: string | null | undefined
): { href: string; tab: CutTab } {
  const tab: CutTab = from === "library" ? "library" : "projects";
  return { href: homeHref(base, tab), tab };
}
