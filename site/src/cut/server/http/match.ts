// Generic route-table matcher shared by the Cut engine router (http/routes.ts)
// and the hosted cloud router (cloud/routes.ts). It lives in its own leaf module
// so the cloud mount can import the matcher without pulling the engine's module
// graph into a hosted bundle.

export interface RouteEntry {
  method: "GET" | "POST" | "PUT" | "DELETE";
  path: string; // ":name" segments bind params
}

export type RouteTableMatch<T extends RouteEntry> =
  | { route: T; params: Record<string, string>; head: boolean }
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
 * Match a request against a route table, mirroring Next's routing so every
 * mount behaves identically: static path segments win over dynamic ones, HEAD
 * is served by the GET handler, and a path that exists for other methods
 * returns 405 (not a dynamic-route false match).
 */
export function matchRouteTable<T extends RouteEntry>(
  routes: readonly T[],
  method: string,
  pathname: string
): RouteTableMatch<T> | null {
  const segs = pathname.split("/").filter(Boolean);
  const wanted = method === "HEAD" ? "GET" : method;

  const matches = routes
    .map((route) => {
      const bound = bindPath(route.path, segs);
      return bound ? { route, params: bound.params, score: bound.score } : null;
    })
    .filter((m) => m !== null);
  if (matches.length === 0) return null;

  // The most-literal path is the single route Next would pick for this URL.
  const top = Math.max(...matches.map((m) => m.score));
  const chosen = matches.filter((m) => m.score === top);

  const hit = chosen.find((m) => m.route.method === wanted);
  if (hit) return { route: hit.route, params: hit.params, head: method === "HEAD" };

  // Path matched but this method has no handler → 405, as Next returns.
  const allow = new Set<string>(chosen.map((m) => m.route.method));
  if (allow.has("GET")) allow.add("HEAD");
  allow.add("OPTIONS");
  return { methodNotAllowed: [...allow] };
}
