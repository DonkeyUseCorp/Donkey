// Cut's client reaches its engine two ways. Served locally (cut.localhost,
// localhost) the page and the engine share an origin, so paths stay relative.
// Served from the hosted domain (cut.donkeyuse.com) the page is just static
// html/js — the Cut APIs are switched off on that host — so every API call
// targets the engine running on this Mac instead. Loopback is a trustworthy
// origin, so the https page may call it; the engine grants the hosted origin
// CORS (see src/proxy.ts).
//
// The engine is found by probing its health endpoint across candidate ports:
// the downloadable engine's dedicated port first, then the dev server's 3000.
// The first healthy origin wins and is remembered for the session.
import { DEFAULT_ENGINE_PORT } from "./ports";

const ENGINE_PORTS = [DEFAULT_ENGINE_PORT, 3000];
const PROBE_TIMEOUT_MS = 1200;

const isLocalHost = (hostname: string) =>
  hostname === "localhost" || hostname === "127.0.0.1" || hostname.endsWith(".localhost");

let resolvedOrigin: string | null = null; // "" = same origin
let resolving: Promise<string> | null = null;

function candidates(): string[] {
  // Manual override for unusual setups, e.g. an engine on a custom port.
  const saved = localStorage.getItem("cut-engine-origin");
  return [...(saved ? [saved] : []), ...ENGINE_PORTS.map((p) => `http://127.0.0.1:${p}`)];
}

async function probe(origin: string): Promise<boolean> {
  try {
    const res = await fetch(`${origin}/api/cut/engine/health`, {
      signal: AbortSignal.timeout(PROBE_TIMEOUT_MS),
    });
    return res.ok;
  } catch {
    return false;
  }
}

/** Resolve (and memoize) the engine origin; throws when no engine answers so
 * callers surface the "start Donkey Cut on this Mac" state. A failed attempt
 * is not memoized — the next call probes again. */
export function engineReady(): Promise<string> {
  if (resolvedOrigin !== null) return Promise.resolve(resolvedOrigin);
  resolving ??= (async () => {
    if (typeof window === "undefined" || isLocalHost(window.location.hostname)) {
      resolvedOrigin = "";
      return "";
    }
    for (const c of candidates()) {
      if (await probe(c)) {
        resolvedOrigin = c;
        return c;
      }
    }
    throw new Error("No Donkey Cut engine is reachable on this Mac.");
  })().finally(() => {
    resolving = null;
  });
  return resolving;
}

/** The engine origin as currently known ("" while same-origin or unresolved).
 * URLs built from it are correct once any apiFetch has succeeded. */
export function engineOrigin(): string {
  return resolvedOrigin ?? "";
}

/** Absolute-or-relative URL for an engine API path. */
export const apiUrl = (path: string) => `${engineOrigin()}${path}`;

/** fetch() against the engine, resolving it first. */
export async function apiFetch(path: string, init?: RequestInit) {
  const base = await engineReady();
  return fetch(`${base}${path}`, init);
}

/** JSON body of an engine reply. A reply that never reached a handler is plain
 * text — a 404/405 from an engine build older than the route, a 403 refusal —
 * so a non-JSON body folds into an `error` message instead of throwing a
 * SyntaxError at the caller's parse. The 404/405 case is the hosted page
 * driving an out-of-date engine: the page updates on deploy, the engine only
 * when the user updates the Donkey app. */
export async function apiJson<T>(res: Response): Promise<T & { error?: string }> {
  const text = await res.text();
  try {
    return JSON.parse(text) as T & { error?: string };
  } catch {
    const stale = res.status === 404 || res.status === 405;
    return {
      error: stale
        ? "The Donkey app on this Mac doesn't support this yet — update Donkey and try again."
        : text.trim() || `The engine replied ${res.status}.`,
    } as T & { error?: string };
  }
}
