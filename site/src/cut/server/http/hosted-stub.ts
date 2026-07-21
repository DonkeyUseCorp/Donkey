// On a hosted build, next.config.ts aliases "@/cut/server/http/next" to this
// stub (gated on process.env.VERCEL). Cut is local-only: every Cut API 404s on
// hosted, so the real engine router never needs to load there. Aliasing it away
// keeps its module graph — including the cwd-rooted file operations Turbopack's
// tracer would otherwise follow, sweeping local media, stock video, and the
// ~220MB Claude Agent SDK CLI binary into the serverless function — out of the
// deployed /api/cut function so it fits Vercel's size limit.
export async function cutCatchAll(): Promise<Response> {
  return new Response(null, { status: 404 });
}
