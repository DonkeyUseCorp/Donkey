import type { Metadata } from "next";
import type { ReactNode } from "react";
import { headers } from "next/headers";

import { AppSurfaceBackground } from "@/app/app/_components/AppSurfaceBackground";
import { isCutHost } from "@/cut/lib/hosts";
import { CutBaseProvider } from "@/cut/lib/nav";

export const metadata: Metadata = {
  title: "Donkey Cut",
  description: "A video editor that does all its work on your Mac.",
};

// Cut (the video editor) renders on the same white product surface as Donkey's
// /app, not the cream marketing background. AppSurfaceBackground paints the root
// html white so the cream landing background does not show through the overscroll
// area, and font-system matches the /app system font stack.
export default async function CutLayout({ children }: { children: ReactNode }) {
  // The app's routes live under /cut/*. On the cut.* production host a proxy
  // rewrite serves them at the root, so links are root-relative (base ""). In
  // local dev the app is opened at /cut on the apex — same origin as the session
  // cookie — so links carry the "/cut" base. Resolve it once from the host.
  const base = isCutHost((await headers()).get("host")) ? "" : "/cut";
  return (
    <div className="min-h-screen bg-white font-system text-foreground antialiased">
      <AppSurfaceBackground />
      <CutBaseProvider base={base}>{children}</CutBaseProvider>
    </div>
  );
}
