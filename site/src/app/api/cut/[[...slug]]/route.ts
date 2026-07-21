import { isHostedRuntime } from "@/cut/server/local-only";

// The whole Cut API lives under /api/cut/* and routes through the shared table
// (src/cut/server/http/routes.ts) — the same one the packaged engine mounts.
//
// Cut is local-only: on a hosted deploy every Cut API 404s. The 404 is returned
// here, before the dynamic import that pulls the router, so the engine's module
// graph — including the ~220MB Claude Agent SDK CLI binary that ai.ts imports —
// never loads on hosted. next.config's outputFileTracingExcludes then drops that
// binary from the deployed function so it fits Vercel's size limit.
export const runtime = "nodejs";

async function handle(req: Request): Promise<Response> {
  if (isHostedRuntime()) return new Response(null, { status: 404 });
  const { cutCatchAll } = await import("@/cut/server/http/next");
  return cutCatchAll(req);
}

export const GET = handle;
export const POST = handle;
export const PUT = handle;
export const DELETE = handle;
