// Cut is a local-only product. Its server APIs run on the user's own Mac —
// against their local ffmpeg/swiftc, their own claude/codex CLI logins, and
// local disk. They must never execute on hosted infrastructure, both because
// the tools and files aren't there and because those routes are unauthenticated
// by design (fine on localhost, an exposure on a public host).
//
// On a hosted deploy, cut.donkeyuse.com still serves Cut's client bundle, but
// every server API is switched off — so nothing reads local disk, spawns a
// process, or reaches any model, including our production models. Cut's AI only
// ever uses the user's local claude/codex logins; it has no path to hosted
// inference, and this guard keeps it that way.
//
// `VERCEL` is set on every Vercel build and runtime and is absent when running
// locally, so this guard is inert during local dev and a local `npm run start`,
// and only trips on a real deploy.

export function isHostedRuntime(): boolean {
  return Boolean(process.env.VERCEL);
}

/** Guard shared server code that touches local disk or spawns a process. */
export function assertLocalRuntime(): void {
  if (isHostedRuntime()) {
    throw new Error("Cut is local-only; its server APIs do not run on hosted infrastructure.");
  }
}

/** 404 a Cut API route when hosted; return null to proceed locally. */
export function hostedApiBlock(): Response | null {
  return isHostedRuntime() ? new Response(null, { status: 404 }) : null;
}
