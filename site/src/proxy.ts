import { NextResponse, type NextRequest } from "next/server";

// Cut (the video editor, publicly "Donkey Cut") is served on the
// cut.donkeyuse.com subdomain, but its routes live under /cut in this single
// site app. For requests on the Cut host we rewrite page paths to /cut/* so
// Cut's root-relative links (/, /library, /p/[id]) resolve to its routes, while
// the apex host keeps serving Donkey.
//
// This file must live in src/ (next to app/) and use the Next 16 `proxy` name;
// a root-level middleware.ts is not loaded when the app is under src/.
//
// Local dev: add nothing to /etc/hosts — `cut.localhost` already resolves to
// 127.0.0.1, so http://cut.localhost:3000/ exercises this path.
const CUT_HOSTS = new Set(["cut.donkeyuse.com", "cut.localhost"]);

// Cut's server APIs are local-only (see src/cut/server/local-only.ts): the
// hosted deploy serves only Cut's client bundle, and that page drives the
// engine running on the user's own Mac. Two rules follow:
//  - hosted: these API paths 404 before any handler runs, so no Cut server
//    code (disk, ffmpeg, the user's AI CLIs) can execute off-Mac and the
//    unauthenticated routes are unreachable.
//  - local: the page served from the hosted origin calls this engine
//    cross-origin, so grant exactly that origin CORS.
const CUT_API_PREFIXES = ["/api/ai", "/api/export", "/api/library", "/api/projects"];
const CUT_CLIENT_ORIGINS = new Set(["https://cut.donkeyuse.com"]);
const HOSTED = Boolean(process.env.VERCEL);

const isCutApi = (pathname: string) =>
  CUT_API_PREFIXES.some((p) => pathname === p || pathname.startsWith(`${p}/`));

function cutApi(req: NextRequest): NextResponse {
  if (HOSTED) return new NextResponse(null, { status: 404 });

  const origin = req.headers.get("origin") ?? "";
  if (!CUT_CLIENT_ORIGINS.has(origin)) return NextResponse.next();

  if (req.method === "OPTIONS") {
    return new NextResponse(null, {
      status: 204,
      headers: {
        "Access-Control-Allow-Origin": origin,
        "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
        "Access-Control-Allow-Headers":
          req.headers.get("access-control-request-headers") ?? "Content-Type",
        // Chrome preflights public-site → local-network requests.
        "Access-Control-Allow-Private-Network": "true",
        "Access-Control-Max-Age": "86400",
        Vary: "Origin",
      },
    });
  }
  const res = NextResponse.next();
  res.headers.set("Access-Control-Allow-Origin", origin);
  res.headers.set("Vary", "Origin");
  return res;
}

export function proxy(req: NextRequest) {
  const { pathname } = req.nextUrl;
  if (isCutApi(pathname)) return cutApi(req);

  const host = (req.headers.get("host") ?? "").split(":")[0];
  if (!CUT_HOSTS.has(host)) return NextResponse.next();

  if (pathname.startsWith("/cut") || pathname.startsWith("/api")) {
    return NextResponse.next();
  }
  const url = req.nextUrl.clone();
  url.pathname = `/cut${pathname === "/" ? "" : pathname}`;
  return NextResponse.rewrite(url);
}

export const config = {
  // Page routes (skip Next internals and files with an extension) plus every
  // Cut API path — including media/export files with extensions — so the
  // hosted 404 and local CORS above cover all of them.
  matcher: [
    "/((?!_next/|.*\\..*).*)",
    "/api/ai/:path*",
    "/api/export/:path*",
    "/api/library/:path*",
    "/api/projects/:path*",
  ],
};
