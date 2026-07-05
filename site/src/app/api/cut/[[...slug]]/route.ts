import { cutCatchAll } from "@/cut/server/http/next";

// The whole Cut API lives under /api/cut/* and routes through the shared table
// (src/cut/server/http/routes.ts) — the same one the packaged engine mounts.
export const runtime = "nodejs";

export const GET = cutCatchAll;
export const POST = cutCatchAll;
export const PUT = cutCatchAll;
export const DELETE = cutCatchAll;
