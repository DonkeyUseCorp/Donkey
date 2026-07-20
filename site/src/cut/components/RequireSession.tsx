"use client";

import { useEffect, type ReactNode } from "react";

import { signInHrefFor } from "@/app/_components/landing/useAppEntryHref";
import { DONKEYCUT_CANONICAL } from "@/cut/lib/hosts";
import { authClient } from "@/lib/auth-client";
import { useCutBase } from "@/cut/lib/nav";

// Session gate for the whole Cut app surface. The landing CTAs already route
// signed-out clicks through /sign-in (useAppEntryHref); this covers direct
// navigation to an app URL the same way, sending the visitor to sign-in with
// the URL they wanted as the post-auth callback. While the session is still
// resolving the app renders normally, so signed-in users (the common case) see
// no gate at all.
//
// The legacy host (base "") has no /sign-in of its own — donkeycut.com owns
// auth — so its URLs redirect to the canonical host, mapped onto the same app
// under /app. Project state lives in the local engine, so it survives the host
// move.
export function RequireSession({ children }: { children: ReactNode }) {
  const { data: session, isPending } = authClient.useSession();
  const base = useCutBase();

  const signedOut = !isPending && !session;

  useEffect(() => {
    if (!signedOut) return;
    const here = window.location.pathname + window.location.search;
    window.location.replace(
      base === ""
        ? `${DONKEYCUT_CANONICAL}${signInHrefFor(here === "/" ? "/app" : `/app${here}`)}`
        : signInHrefFor(here),
    );
  }, [signedOut, base]);

  if (signedOut) return null;
  return <>{children}</>;
}
