import { NextResponse, type NextRequest } from "next/server";

import { allowedOrigin, corsHeaders, preflightHeaders } from "@/cut/server/cors";
import { isCutHost } from "@/cut/lib/hosts";

// Cut (the video editor, publicly "Donkey Cut") is served on the
// cut.donkeyuse.com subdomain, but its routes live under /cut in this single
// site app. For requests on the Cut host we rewrite page paths to /cut/* so
// Cut's root-relative links (/, /library, /p/[id]) resolve to its routes, while
// the apex host keeps serving Donkey.
//
// Local dev is not a Cut host: the editor is opened at localhost:3000/cut/… so
// its session cookie is same-origin, and its links carry the "/cut" base
// directly (see src/cut/lib/nav.tsx), needing no rewrite.
//
// This file must live in src/ (next to app/) and use the Next 16 `proxy` name;
// a root-level middleware.ts is not loaded when the app is under src/.

// Cut's server APIs are local-only (see src/cut/server/local-only.ts): the
// hosted deploy serves only Cut's client bundle, and that page drives the
// engine running on the user's own Mac. Two rules follow:
//  - hosted: these API paths 404 before any handler runs, so no Cut server
//    code (disk, ffmpeg, the user's AI CLIs) can execute off-Mac and the
//    unauthenticated routes are unreachable.
//  - local: the page served from the hosted origin calls this engine
//    cross-origin, so grant exactly that origin CORS.
const CUT_API_PREFIX = "/api/cut";
const HOSTED = Boolean(process.env.VERCEL);

const isCutApi = (pathname: string) =>
  pathname === CUT_API_PREFIX || pathname.startsWith(`${CUT_API_PREFIX}/`);

function cutApi(req: NextRequest): NextResponse {
  if (HOSTED) return new NextResponse(null, { status: 404 });

  // Same CORS policy as the packaged engine (src/cut/server/cors.ts): grant the
  // hosted Cut origin, pass everything else through as same-origin dev traffic.
  const cors = allowedOrigin(req.headers.get("origin") ?? "");
  if (!cors) return NextResponse.next();

  if (req.method === "OPTIONS") {
    return new NextResponse(null, {
      status: 204,
      headers: preflightHeaders(cors, req.headers.get("access-control-request-headers")),
    });
  }
  const res = NextResponse.next();
  for (const [k, v] of Object.entries(corsHeaders(cors))) res.headers.set(k, v);
  return res;
}

export function proxy(req: NextRequest) {
  const { pathname } = req.nextUrl;
  if (isCutApi(pathname)) return cutApi(req);

  if (!isCutHost(req.headers.get("host"))) return NextResponse.next();

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
    "/api/cut/:path*",
  ],
};
