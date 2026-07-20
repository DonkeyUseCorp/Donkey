"use client";

import { authClient } from "@/lib/auth-client";

// Sign-in lives at the root-level /sign-in on the auth-owning host (donkeycut.com
// owns auth directly), and the AuthScreen there already offers a "Create account"
// toggle — so one sign-in link covers both "log in" and "sign up". The app target
// (already root-prefixed for the host) rides along as the post-auth callback.
export function signInHrefFor(appTarget: string): string {
  return `/sign-in?callbackURL=${encodeURIComponent(appTarget)}`;
}

// Sign-up mirror of signInHrefFor; the auth screens read callbackURL from the
// query string in either mode.
export function signUpHrefFor(appTarget: string): string {
  return `/sign-up?callbackURL=${encodeURIComponent(appTarget)}`;
}

// Where a landing CTA should actually go: straight into the app when signed in,
// or to sign-in when signed out. During the initial (pending) client render the
// session is unknown, matching the static server HTML, so CTAs render the app
// target first and swap to the sign-in link once a signed-out session resolves.
export function useAppEntryHref(): (appTarget: string) => string {
  const { data: session, isPending } = authClient.useSession();
  return (appTarget: string) =>
    isPending || session ? appTarget : signInHrefFor(appTarget);
}
