"use client";

import { useEffect, type ReactNode } from "react";

import { authHrefFor } from "@/app/_components/landing/useAppEntryHref";
import { setEngineUser } from "@/cut/lib/api";
import { syncAccountFlags } from "@/cut/lib/flags";
import { useAppLoaded } from "@/lib/analytics";
import { authClient } from "@/lib/auth-client";

// Session gate for the whole Cut app surface. The landing CTAs already route
// signed-out clicks through /sign-in (useAppEntryHref); this covers direct
// navigation to an app URL the same way, sending the visitor to sign-in with
// the URL they wanted as the post-auth callback.
//
// The app renders only once the session is known: every engine URL carries
// the account id (the engine keeps each account's data separate), so a
// component rendered earlier would build unscoped media URLs. Holding
// children until the id is bound makes that impossible; the session check is
// a fast same-origin cookie read, and the ConnectGate's own connect flow
// covers the moment visually.
export function RequireSession({ children }: { children: ReactNode }) {
  const { data: session, isPending } = authClient.useSession();

  const signedOut = !isPending && !session;

  useAppLoaded("cut", session?.user);

  // The web-mode flag lives on the account; refresh the local mirror once the
  // session is known so a grant (or revoke) from another device takes effect
  // on the next load here.
  const userId = session?.user.id;
  useEffect(() => {
    if (userId) void syncAccountFlags();
  }, [userId]);

  useEffect(() => {
    if (!signedOut) return;
    const here = window.location.pathname + window.location.search;
    window.location.replace(authHrefFor("/sign-in", here));
  }, [signedOut]);

  if (!session) return null;
  setEngineUser(session.user.id);
  return <>{children}</>;
}
