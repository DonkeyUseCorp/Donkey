// Cut's client reaches its engine two ways. Served locally (cut.localhost,
// localhost) the page and the engine share an origin, so paths stay relative.
// Served from the hosted domain (cut.donkeyuse.com) the page is just static
// html/js — the Cut APIs are switched off on that host — so every API call
// targets the engine running on this Mac at 127.0.0.1 instead. Loopback is a
// trustworthy origin, so the https page may call it; the engine's proxy grants
// the hosted origin CORS (see src/proxy.ts).
const DEFAULT_ENGINE = "http://127.0.0.1:3000";

const isLocalHost = (hostname: string) =>
  hostname === "localhost" || hostname === "127.0.0.1" || hostname.endsWith(".localhost");

/** "" when the page is served by the engine itself; the engine's origin when
 * the page came from the hosted domain. Override via localStorage key
 * "cut-engine-origin" when the engine runs on a non-default port. */
export function engineOrigin(): string {
  if (typeof window === "undefined") return "";
  if (isLocalHost(window.location.hostname)) return "";
  return localStorage.getItem("cut-engine-origin") ?? DEFAULT_ENGINE;
}

/** Absolute-or-relative URL for an engine API path. */
export const apiUrl = (path: string) => `${engineOrigin()}${path}`;

/** fetch() against the engine. */
export const apiFetch = (path: string, init?: RequestInit) => fetch(apiUrl(path), init);
