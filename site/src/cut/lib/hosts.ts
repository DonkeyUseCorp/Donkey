// Cut is served from two production hosts, mapped by src/proxy.ts onto the
// real routes under /cut:
//
//   donkeycut.com       the Cut product domain — marketing landing at "/",
//                       the app at "/app/…" (rewritten to /cut/app/…).
//   cut.donkeyuse.com   the legacy host — the app at its root ("/", "/p/[id]",
//                       rewritten to /cut/app/…), unchanged for existing links.
//
// Local dev is deliberately absent from both sets: localhost gets its own
// proxy branch that mirrors donkeycut.com (Cut at "/", Donkey Use under /use),
// keeping the session cookie same-origin on the one dev origin.
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

// Local dev serves Donkey Cut by default: the proxy gives localhost the same
// "/…" → "/cut/…" mapping as donkeycut.com, with Donkey Use reachable under
// /use (see src/proxy.ts).
export function isLocalHost(host: string | null | undefined): boolean {
  const name = hostname(host);
  return name === "localhost" || name === "127.0.0.1";
}

// The link base every in-app Cut href is built on (see src/cut/lib/nav.tsx).
// The hosted apex (donkeyuse.com) serves the Cut tree unrewritten at /cut/app.
export function cutAppBase(host: string | null | undefined): string {
  if (isCutHost(host)) return "";
  if (isDonkeycutHost(host) || isLocalHost(host)) return "/app";
  return "/cut/app";
}
