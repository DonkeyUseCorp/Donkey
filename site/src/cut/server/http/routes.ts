import { aiApi } from "./ai";
import { engineApi } from "./engine";
import { exportApi } from "./export";
import { libraryApi } from "./library";
import { projectsApi } from "./projects";

type TableHandler = (req: Request, params: Record<string, string>) => Response | Promise<Response>;

interface CutRoute {
  method: "GET" | "POST" | "PUT" | "DELETE";
  path: string; // ":name" segments bind params
  handler: TableHandler;
}

/**
 * The whole Cut API surface in one table, namespaced under /api/cut/* to keep it
 * clear of Donkey's own APIs. Both mounts dispatch through it — the Next
 * catch-all route and the packaged engine — so the two surfaces cannot drift.
 */
export const CUT_ROUTES: CutRoute[] = [
  { method: "GET", path: "/api/cut/engine/health", handler: () => engineApi.health() },

  { method: "GET", path: "/api/cut/projects", handler: () => projectsApi.list() },
  { method: "POST", path: "/api/cut/projects", handler: (req) => projectsApi.create(req) },
  { method: "GET", path: "/api/cut/projects/folders", handler: () => projectsApi.folders() },
  { method: "POST", path: "/api/cut/projects/folders", handler: (req) => projectsApi.createFolder(req) },
  { method: "PUT", path: "/api/cut/projects/folders/:id", handler: (req, p) => projectsApi.renameFolder(req, { id: p.id }) },
  { method: "DELETE", path: "/api/cut/projects/folders/:id", handler: (req, p) => projectsApi.deleteFolder(req, { id: p.id }) },
  { method: "POST", path: "/api/cut/projects/:id/move", handler: (req, p) => projectsApi.move(req, { id: p.id }) },
  { method: "GET", path: "/api/cut/projects/:id", handler: (req, p) => projectsApi.get(req, { id: p.id }) },
  { method: "PUT", path: "/api/cut/projects/:id", handler: (req, p) => projectsApi.put(req, { id: p.id }) },
  { method: "DELETE", path: "/api/cut/projects/:id", handler: (req, p) => projectsApi.remove(req, { id: p.id }) },
  { method: "POST", path: "/api/cut/projects/:id/media", handler: (req, p) => projectsApi.uploadMedia(req, { id: p.id }) },
  { method: "GET", path: "/api/cut/projects/:id/media/:file", handler: (req, p) => projectsApi.serveMedia(req, { id: p.id, file: p.file }) },
  { method: "GET", path: "/api/cut/projects/:id/exports", handler: (req, p) => projectsApi.listExports(req, { id: p.id }) },
  { method: "GET", path: "/api/cut/projects/:id/exports/:file", handler: (req, p) => projectsApi.serveExport(req, { id: p.id, file: p.file }) },
  { method: "DELETE", path: "/api/cut/projects/:id/exports/:file", handler: (req, p) => projectsApi.removeExport(req, { id: p.id, file: p.file }) },
  { method: "POST", path: "/api/cut/projects/:id/exports/:file/reveal", handler: (req, p) => projectsApi.revealExport(req, { id: p.id, file: p.file }) },
  { method: "POST", path: "/api/cut/projects/:id/transcribe", handler: (req, p) => projectsApi.transcribeStart(req, { id: p.id }) },
  { method: "GET", path: "/api/cut/projects/:id/transcribe", handler: (req, p) => projectsApi.transcribePoll(req, { id: p.id }) },
  { method: "POST", path: "/api/cut/projects/:id/image", handler: (req, p) => projectsApi.importImage(req, { id: p.id }) },
  { method: "POST", path: "/api/cut/projects/:id/freeze", handler: (req, p) => projectsApi.freeze(req, { id: p.id }) },
  { method: "POST", path: "/api/cut/projects/:id/duplicate", handler: (req, p) => projectsApi.duplicate(req, { id: p.id }) },
  { method: "GET", path: "/api/cut/projects/:id/preview", handler: (req, p) => projectsApi.servePreview(req, { id: p.id }) },
  { method: "GET", path: "/api/cut/projects/:id/export-jobs", handler: (req, p) => exportApi.activeForProject(req, { id: p.id }) },

  { method: "GET", path: "/api/cut/library", handler: () => libraryApi.list() },
  { method: "POST", path: "/api/cut/library", handler: (req) => libraryApi.upload(req) },
  { method: "POST", path: "/api/cut/library/use", handler: (req) => libraryApi.use(req) },
  { method: "POST", path: "/api/cut/library/save", handler: (req) => libraryApi.save(req) },
  { method: "POST", path: "/api/cut/library/import-url", handler: (req) => libraryApi.importUrl(req) },
  { method: "POST", path: "/api/cut/library/move", handler: (req) => libraryApi.move(req) },
  { method: "POST", path: "/api/cut/library/templates", handler: (req) => libraryApi.saveTemplate(req) },
  { method: "POST", path: "/api/cut/library/templates/:id/use", handler: (req, p) => libraryApi.useTemplate(req, { id: p.id }) },
  { method: "DELETE", path: "/api/cut/library/templates/:id", handler: (req, p) => libraryApi.removeTemplate(req, { id: p.id }) },
  { method: "POST", path: "/api/cut/library/folders", handler: (req) => libraryApi.createFolder(req) },
  { method: "PUT", path: "/api/cut/library/folders/:id", handler: (req, p) => libraryApi.renameFolder(req, { id: p.id }) },
  { method: "DELETE", path: "/api/cut/library/folders/:id", handler: (req, p) => libraryApi.deleteFolder(req, { id: p.id }) },
  { method: "GET", path: "/api/cut/library/media/:file", handler: (req, p) => libraryApi.serveMedia(req, { file: p.file }) },
  { method: "DELETE", path: "/api/cut/library/:id", handler: (req, p) => libraryApi.remove(req, { id: p.id }) },

  { method: "POST", path: "/api/cut/export", handler: (req) => exportApi.create(req) },
  { method: "GET", path: "/api/cut/export/:jobId", handler: (req, p) => exportApi.status(req, { jobId: p.jobId }) },
  { method: "DELETE", path: "/api/cut/export/:jobId", handler: (req, p) => exportApi.cancel(req, { jobId: p.jobId }) },
  { method: "GET", path: "/api/cut/export/:jobId/file", handler: (req, p) => exportApi.file(req, { jobId: p.jobId }) },

  { method: "POST", path: "/api/cut/ai/chat", handler: (req) => aiApi.chat(req) },
  { method: "POST", path: "/api/cut/ai/captions", handler: (req) => aiApi.captions(req) },
  { method: "POST", path: "/api/cut/ai/visual-subtitles", handler: (req) => aiApi.visualSubtitles(req) },
  { method: "GET", path: "/api/cut/ai/models", handler: () => aiApi.models() },
  { method: "GET", path: "/api/cut/ai/proxy", handler: (req) => aiApi.proxyCatalog(req) },
  { method: "POST", path: "/api/cut/ai/proxy", handler: (req) => aiApi.proxyCall(req) },
  { method: "POST", path: "/api/cut/ai/tool-result", handler: (req) => aiApi.toolResult(req) },
];

export type RouteMatch =
  | { handler: TableHandler; params: Record<string, string>; head: boolean }
  | { methodNotAllowed: string[] };

/** Bind a pattern against path segments. Returns the bound params and a
 * specificity score (count of literal segment matches) so more-literal paths
 * win, or null when the shape doesn't match. Params bind RAW (percent-encoded),
 * matching what Next hands its route files — handlers decode themselves. */
function bindPath(
  pattern: string,
  segs: string[]
): { params: Record<string, string>; score: number } | null {
  const pat = pattern.split("/").filter(Boolean);
  if (pat.length !== segs.length) return null;
  const params: Record<string, string> = {};
  let score = 0;
  for (let i = 0; i < pat.length; i++) {
    const p = pat[i];
    if (p.startsWith(":")) params[p.slice(1)] = segs[i];
    else if (p === segs[i]) score++;
    else return null;
  }
  return { params, score };
}

/**
 * Match a request against the table, mirroring Next's routing so the engine and
 * dev server behave identically: static path segments win over dynamic ones,
 * HEAD is served by the GET handler, and a path that exists for other methods
 * returns 405 (not a dynamic-route false match).
 */
export function matchCutRoute(method: string, pathname: string): RouteMatch | null {
  const segs = pathname.split("/").filter(Boolean);
  const wanted = method === "HEAD" ? "GET" : method;

  const matches = CUT_ROUTES.map((route) => {
    const bound = bindPath(route.path, segs);
    return bound ? { route, params: bound.params, score: bound.score } : null;
  }).filter((m) => m !== null);
  if (matches.length === 0) return null;

  // The most-literal path is the single route Next would pick for this URL.
  const top = Math.max(...matches.map((m) => m.score));
  const chosen = matches.filter((m) => m.score === top);

  const hit = chosen.find((m) => m.route.method === wanted);
  if (hit) return { handler: hit.route.handler, params: hit.params, head: method === "HEAD" };

  // Path matched but this method has no handler → 405, as Next returns.
  const allow = new Set<string>(chosen.map((m) => m.route.method));
  if (allow.has("GET")) allow.add("HEAD");
  allow.add("OPTIONS");
  return { methodNotAllowed: [...allow] };
}
