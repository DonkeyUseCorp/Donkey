import type { ReactNode } from "react";

import { AppSurfaceBackground } from "@/app/app/_components/AppSurfaceBackground";
import { ConnectGate } from "@/cut/components/ConnectGate";
import { RequireSession } from "@/cut/components/RequireSession";

// The Cut app (projects home, library, editor) renders on the same white
// product surface as Donkey's /app, not the cream marketing background of the
// landing page that lives one segment up. AppSurfaceBackground paints the root
// html white so the cream does not show through the overscroll area, and
// font-system matches the /app system font stack. RequireSession gates the
// whole subtree on a signed-in session, redirecting signed-out visitors to
// sign-in with their target URL as the callback. ConnectGate keeps the app
// blurred and inert behind a connect modal until the engine on this Mac
// answers, so the browser's local-network permission prompt only ever fires
// from the user's own Connect click.
export default function CutAppLayout({ children }: { children: ReactNode }) {
  return (
    <div className="min-h-screen bg-white font-system text-foreground antialiased">
      <AppSurfaceBackground />
      <RequireSession>
        <ConnectGate>{children}</ConnectGate>
      </RequireSession>
    </div>
  );
}
