import { AsyncLocalStorage } from "node:async_hooks";
import { mkdir, rename } from "node:fs/promises";
import path from "node:path";
import { cutDataRoot } from "./dataDir";
import { exists } from "./util";

/**
 * Every data route runs inside a signed-in user's scope: the page sends the
 * Donkey account id with each engine request (the `u` query param api.ts
 * appends), the dispatcher binds it here, and all project/library paths hang
 * off users/<id> under the data root. The engine cannot verify the id — it
 * never talks to the hosted backend — so this is per-account separation on a
 * shared Mac, not protection against a hostile local user.
 */
const scope = new AsyncLocalStorage<string>();

// Donkey account ids are URL-safe tokens; anything else is refused before it
// can become a filesystem path.
const USER_ID_RE = /^[A-Za-z0-9_-]{1,64}$/;

export const isValidCutUser = (id: string) => USER_ID_RE.test(id);

export function runWithCutUser<T>(id: string, fn: () => T): T {
  if (!isValidCutUser(id)) throw new Error("Invalid user id.");
  return scope.run(id, fn);
}

/** The current request's per-user data root. Path helpers build on this, so a
 * path outside a user scope is impossible by construction. */
export function cutUserRoot(): string {
  const id = scope.getStore();
  if (!id) throw new Error("No user scope bound to this request.");
  return path.join(cutDataRoot(), "users", id);
}

// Data written before user scoping lived directly under the data root. The
// first account to connect adopts it — the same single owner who could see it
// before — by moving those folders into its own scope.
const LEGACY_DIRS = ["projects", "library"];
let adopting: Promise<void> | null = null;

export function adoptLegacyData(id: string): Promise<void> {
  adopting ??= (async () => {
    const root = cutDataRoot();
    for (const dir of LEGACY_DIRS) {
      const from = path.join(root, dir);
      if (!(await exists(from))) continue;
      const to = path.join(root, "users", id, dir);
      if (await exists(to)) continue;
      await mkdir(path.dirname(to), { recursive: true });
      await rename(from, to);
    }
  })().catch((err) => {
    adopting = null; // retry on the next request instead of pinning the failure
    throw err;
  });
  return adopting;
}
