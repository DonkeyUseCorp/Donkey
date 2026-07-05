import { DEFAULT_ENGINE_PORT } from "../lib/ports";

/**
 * The port the engine binds, from DONKEY_CUT_PORT when set. A bad value throws
 * rather than silently binding a random OS-assigned port that the client's
 * fixed probe list would never find.
 */
export function enginePort(): number {
  const raw = process.env.DONKEY_CUT_PORT;
  if (raw === undefined || raw === "") return DEFAULT_ENGINE_PORT;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 1 || n > 65535) {
    throw new Error(`DONKEY_CUT_PORT must be an integer 1–65535, got "${raw}".`);
  }
  return n;
}

/** The engine's own loopback base URL (honors DONKEY_CUT_PORT). */
export const engineBaseUrl = () => `http://127.0.0.1:${enginePort()}`;
