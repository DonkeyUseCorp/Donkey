import { toNextJsHandler } from "better-auth/next-js";

import { auth } from "@/lib/auth";
import { withHostScopedAuthCookies } from "@/lib/cut-auth";

// Auth responses served to donkeycut.com re-scope their cookies to host-only
// (see src/lib/cut-auth.ts); session refresh and sign-out set cookies through
// this handler, so without it the browser would silently reject them there.
const handler = toNextJsHandler(auth);

export async function GET(request: Request) {
  return withHostScopedAuthCookies(await handler.GET(request), request.headers.get("host"));
}

export async function POST(request: Request) {
  return withHostScopedAuthCookies(await handler.POST(request), request.headers.get("host"));
}
