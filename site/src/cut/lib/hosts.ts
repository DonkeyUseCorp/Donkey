// Hosts that serve the Cut app at their root. On these, the src/proxy.ts rewrite
// maps "/…" to the app's real "/cut/…" routes, so links stay clean ("/p/[id]").
//
// Local dev is deliberately absent: there Cut is served from the apex under
// /cut, so its session cookie is same-origin. A cookie set on `localhost` never
// reaches a `cut.localhost` subdomain in Chrome, so the subdomain can't hold a
// session — the /cut path on the apex is what dev uses instead.
export const CUT_HOSTS = new Set(["cut.donkeyuse.com"]);

export function isCutHost(host: string | null | undefined): boolean {
  if (!host) return false;
  return CUT_HOSTS.has(host.split(":")[0]);
}
