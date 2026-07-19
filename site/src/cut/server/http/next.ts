import { hostedApiBlock } from "../local-only";
import { ensureToolPath } from "../tool-path";
import { matchCutRoute } from "./routes";

/**
 * The Cut API surface as a Next route handler. A single optional-catch-all route
 * (src/app/api/cut/[[...slug]]/route.ts) delegates here, so the Next dev server
 * dispatches through the exact same table (matchCutRoute) the packaged engine
 * mounts — the two surfaces are one router and cannot drift. The hosted shut-off
 * is applied once, here.
 */
export async function cutCatchAll(req: Request): Promise<Response> {
  const blocked = hostedApiBlock();
  if (blocked) return blocked;

  // The dev server spawns tools (yt-dlp, ffmpeg, …) in-process, so it needs
  // the same widened PATH the packaged engine builds at startup.
  await ensureToolPath();

  const { pathname } = new URL(req.url);
  const match = matchCutRoute(req.method, pathname);
  if (!match) return new Response("Not found.", { status: 404 });
  if ("methodNotAllowed" in match) {
    return new Response("Method not allowed.", {
      status: 405,
      headers: { Allow: match.methodNotAllowed.join(", ") },
    });
  }

  const res = await match.handler(req, match.params);
  // A HEAD reply carries the GET headers but no body.
  if (match.head && res.body) {
    void res.body.cancel();
    return new Response(null, { status: res.status, headers: res.headers });
  }
  return res;
}
