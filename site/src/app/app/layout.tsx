import type { ReactNode } from "react";

import { AppSurfaceBackground } from "@/app/app/_components/AppSurfaceBackground";

// The /app surface is the signed-in product UI. Unlike the cream landing page,
// it always renders on a white background and uses the same system font as the
// marketing site (the --font-system token shared by the landing page).
// AppSurfaceBackground also paints the root html white so the cream landing
// background does not show through in the overscroll area.
export default function AppLayout({ children }: { children: ReactNode }) {
  return (
    <div className="min-h-screen bg-white font-system text-foreground">
      <AppSurfaceBackground />
      {children}
    </div>
  );
}
