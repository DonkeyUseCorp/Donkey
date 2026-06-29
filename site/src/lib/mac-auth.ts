/**
 * The custom URL scheme the website uses to hand a completed Mac sign-in back to
 * the native app, plus the origin Better Auth trusts for that handoff.
 *
 * Local `next dev` targets the dev build's `donkey-dev://` (so the handoff never
 * collides with an installed release that owns `donkey://`); every deployed build
 * targets the shipped `donkey://`. Google OAuth is unaffected — its redirect_uri
 * is the website's own callback, which never sees this scheme.
 */
export function macAuthCallbackScheme(): string {
  return process.env.NODE_ENV === "development" ? "donkey-dev" : "donkey";
}

export function macAuthRedirectOrigins(): string[] {
  return [`${macAuthCallbackScheme()}://`];
}
