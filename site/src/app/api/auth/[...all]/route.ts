import { toNextJsHandler } from "better-auth/next-js";

import { auth } from "@/lib/auth";

// donkeycut.com owns auth directly, so its cookies are already host-valid — no
// per-host cookie re-scoping is needed. better-auth's handler serves GET/POST
// for the whole /api/auth/* surface (sign-in, callback, session, sign-out).
export const { GET, POST } = toNextJsHandler(auth);
