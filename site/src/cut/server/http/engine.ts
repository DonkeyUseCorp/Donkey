/** The engine's version: the Donkey app passes its own release version when it
 * spawns the engine, so engine updates ride app updates. "dev" everywhere
 * else (Next dev server, a hand-run engine). */
const engineVersion = () => process.env.DONKEY_CUT_VERSION ?? "dev";

export const engineApi = {
  /** Probed by the client to find the engine; version feeds the update nudge. */
  async health() {
    return Response.json({ ok: true, engine: "donkey-cut", version: engineVersion() });
  },
};
