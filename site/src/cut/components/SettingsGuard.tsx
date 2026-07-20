"use client";

import { useEffect, type ReactNode } from "react";

import { Skeleton } from "@/components/ui/skeleton";
import { signInUrl } from "@/cut/lib/generate";
import { authClient } from "@/lib/auth-client";

// Session guard for Cut's billing and usage pages. Signed-out visitors go
// through the same host-aware sign-in flow as the editor's generation
// surfaces (signInUrl): the same-host sign-in page (Google's redirect_uri is
// pinned to the auth-owning host). Reading window.location is safe from
// hydration mismatch: the redirect runs only after the client session resolves.
export function SettingsGuard({ children }: { children: ReactNode }) {
  const { data: session, isPending } = authClient.useSession();

  useEffect(() => {
    if (isPending || session) return;
    window.location.assign(signInUrl());
  }, [isPending, session]);

  if (isPending || !session) {
    return (
      <div className="mx-auto max-w-3xl px-8 py-10">
        <Skeleton className="h-8 w-48" />
        <Skeleton className="mt-6 h-40 w-full" />
      </div>
    );
  }

  return <>{children}</>;
}
