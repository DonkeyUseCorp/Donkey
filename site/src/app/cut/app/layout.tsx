import type { ReactNode } from "react";

import { AppSurfaceBackground } from "@/app/app/_components/AppSurfaceBackground";

// The Cut app (projects home, library, editor) renders on the same white
// product surface as Donkey's /app, not the cream marketing background of the
// landing page that lives one segment up. AppSurfaceBackground paints the root
// html white so the cream does not show through the overscroll area, and
// font-system matches the /app system font stack.
export default function CutAppLayout({ children }: { children: ReactNode }) {
  return (
    <div className="min-h-screen bg-white font-system text-foreground antialiased">
      <AppSurfaceBackground />
      {children}
    </div>
  );
}
