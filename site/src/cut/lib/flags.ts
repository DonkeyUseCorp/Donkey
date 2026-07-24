// Cut's web-mode flag is an ACCOUNT feature flag ("cut-web-mode"), enabled per
// user in the account settings' Feature flags section. localStorage only
// mirrors the server value so reads stay synchronous; RequireSession refreshes
// the mirror from the account on every app load, and the settings page updates
// it when the user flips the switch. Reads go through useSyncExternalStore so
// every component — and every other tab, via the storage event — reacts to a
// change immediately.
import { useSyncExternalStore } from "react";

const WEB_MODE_KEY = "cut-web-mode";
const FLAG_EVENT = "cut-flags-changed";

export function webModeEnabled(): boolean {
  if (typeof window === "undefined") return false;
  return localStorage.getItem(WEB_MODE_KEY) === "1";
}

/** Update the local mirror (this tab reacts immediately, other tabs via the
 * storage event). The account value is written by the settings page's PUT;
 * this never calls the server. */
export function applyWebModeLocal(on: boolean) {
  if (on) localStorage.setItem(WEB_MODE_KEY, "1");
  else localStorage.removeItem(WEB_MODE_KEY);
  window.dispatchEvent(new Event(FLAG_EVENT));
}

/** Turn the account flag on (same PUT the settings page issues) and mirror it
 * locally on success. Returns whether the account write landed. */
export async function enableWebMode(): Promise<boolean> {
  const res = await fetch("/api/account/feature-flags", {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ flag: WEB_MODE_KEY, enabled: true }),
  }).catch(() => null);
  if (!res?.ok) return false;
  applyWebModeLocal(true);
  return true;
}

/** Refresh the mirror from the signed-in account's flags. Errors keep the
 * current mirror — a transient fetch failure must not flip the editor's
 * backend out from under the user. */
export async function syncAccountFlags() {
  try {
    const res = await fetch("/api/account/feature-flags");
    if (!res.ok) return;
    const body = (await res.json()) as { flags?: { id: string; enabled: boolean }[] };
    const webMode = body.flags?.find((f) => f.id === WEB_MODE_KEY);
    if (webMode && webMode.enabled !== webModeEnabled()) applyWebModeLocal(webMode.enabled);
  } catch {
    // Offline or hosted API unreachable; the mirror stands.
  }
}

function subscribe(onChange: () => void) {
  window.addEventListener(FLAG_EVENT, onChange);
  window.addEventListener("storage", onChange);
  return () => {
    window.removeEventListener(FLAG_EVENT, onChange);
    window.removeEventListener("storage", onChange);
  };
}

export function useWebMode(): boolean {
  return useSyncExternalStore(subscribe, webModeEnabled, () => false);
}
