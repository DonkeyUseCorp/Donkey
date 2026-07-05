import { NextResponse, type NextRequest } from "next/server";

// Cut (the video editor) is served on the cut.donkeyuse.com subdomain, but its
// routes live under /cut in this single site app. For requests on the Cut host we
// rewrite page paths to /cut/* so Cut's root-relative links (/, /library,
// /p/[id]) resolve to its routes, while the apex host keeps serving Donkey.
// /api/* and Next internals are left untouched — Cut's API handlers are mounted
// under the shared /api tree and don't collide with Donkey's.
//
// This file must live in src/ (next to app/) and use the Next 16 `proxy` name;
// a root-level middleware.ts is not loaded when the app is under src/.
//
// Local dev: add nothing to /etc/hosts — `cut.localhost` already resolves to
// 127.0.0.1, so http://cut.localhost:3000/ exercises this path.
const CUT_HOSTS = new Set(["cut.donkeyuse.com", "cut.localhost"]);

export function proxy(req: NextRequest) {
  const host = (req.headers.get("host") ?? "").split(":")[0];
  if (!CUT_HOSTS.has(host)) return NextResponse.next();

  const { pathname } = req.nextUrl;
  if (pathname.startsWith("/cut") || pathname.startsWith("/api")) {
    return NextResponse.next();
  }
  const url = req.nextUrl.clone();
  url.pathname = `/cut${pathname === "/" ? "" : pathname}`;
  return NextResponse.rewrite(url);
}

export const config = {
  // Run for page routes; skip Next internals and files with an extension.
  matcher: ["/((?!_next/|.*\\..*).*)"],
};
