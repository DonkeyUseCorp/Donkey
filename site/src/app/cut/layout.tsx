import type { Metadata } from "next";
import type { ReactNode } from "react";

import { AppSurfaceBackground } from "@/app/app/_components/AppSurfaceBackground";

export const metadata: Metadata = {
  title: "Donkey Cut",
  description: "A video editor that does all its work on your Mac.",
};

// Cut (the video editor) renders on the same white product surface as Donkey's
// /app, not the cream marketing background. AppSurfaceBackground paints the root
// html white so the cream landing background does not show through the overscroll
// area, and font-system matches the /app system font stack.
export default function CutLayout({ children }: { children: ReactNode }) {
  return (
    <div className="min-h-screen bg-white font-system text-foreground antialiased">
      <AppSurfaceBackground />
      {children}
    </div>
  );
}
