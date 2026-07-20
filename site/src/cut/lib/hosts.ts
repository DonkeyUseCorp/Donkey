// Cut is served from two production hosts, mapped by src/proxy.ts onto the
// real routes under /cut:
//
//   donkeycut.com       the Cut product domain — marketing landing at "/",
//                       the app at "/app/…" (rewritten to /cut/app/…).
//   cut.donkeyuse.com   the legacy host — the app at its root ("/", "/p/[id]",
//                       rewritten to /cut/app/…), unchanged for existing links.
//
// Local dev is deliberately absent from both sets: there Cut is served from the
// apex under /cut, so its session cookie is same-origin. A cookie set on
// `localhost` never reaches a `cut.localhost` subdomain in Chrome, so a
// subdomain can't hold a session — the /cut path on the apex is what dev uses.
export const CUT_HOSTS = new Set(["cut.donkeyuse.com"]);

export const DONKEYCUT_HOSTS = new Set(["donkeycut.com", "www.donkeycut.com"]);

export const DONKEYCUT_CANONICAL = "https://donkeycut.com";

// The apex origin that owns auth (Google OAuth redirect_uri, session minting).
// donkeycut.com signs in by bouncing through it — see /cut-auth.
export const DONKEY_APEX_ORIGIN = "https://donkeyuse.com";

function hostname(host: string | null | undefined): string {
  return host ? host.split(":")[0] : "";
}

export function isCutHost(host: string | null | undefined): boolean {
  return CUT_HOSTS.has(hostname(host));
}

export function isDonkeycutHost(host: string | null | undefined): boolean {
  return DONKEYCUT_HOSTS.has(hostname(host));
}

// The link base every in-app Cut href is built on (see src/cut/lib/nav.tsx).
export function cutAppBase(host: string | null | undefined): string {
  if (isCutHost(host)) return "";
  if (isDonkeycutHost(host)) return "/app";
  return "/cut/app";
}
