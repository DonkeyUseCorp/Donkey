import type { Metadata } from "next";
import type { ReactNode } from "react";
import { headers } from "next/headers";

import { cutAppBase } from "@/cut/lib/hosts";
import { CutBaseProvider } from "@/cut/lib/nav";

export const metadata: Metadata = {
  title: "Donkey Cut",
  description: "A video editor that does all its work on your Mac.",
};

// This layout only resolves the app link base; surface styling belongs to the
// children. The landing page at /cut renders on the cream marketing background,
// while the app subtree under /cut/app paints its own white product surface.
//
// The app's routes live under /cut/app/*. Per host they are served as:
//   cut.donkeyuse.com  → proxy rewrites "/…" → "/cut/app/…"   (base "")
//   donkeycut.com      → proxy rewrites "/app/…" → "/cut/app/…" (base "/app")
//   local dev          → same mapping as donkeycut.com (base "/app")
//   hosted apex        → no rewrite, served at /cut/app directly (base "/cut/app")
export default async function CutLayout({ children }: { children: ReactNode }) {
  const base = cutAppBase((await headers()).get("host"));
  return <CutBaseProvider base={base}>{children}</CutBaseProvider>;
}
