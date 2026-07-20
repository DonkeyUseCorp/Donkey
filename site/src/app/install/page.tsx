import type { Metadata } from "next";
import { headers } from "next/headers";
import { notFound } from "next/navigation";

import { BG, BLACK } from "@/app/_components/landing/theme";
import { CutFooter } from "@/app/cut/_components/landing/CutFooter";
import { CutTopNav } from "@/app/cut/_components/landing/CutTopNav";
import { InstallInstructions } from "@/app/install/_components/InstallInstructions";
import {
  DONKEYCUT_CANONICAL,
  isDonkeycutHost,
  isLocalHost,
} from "@/cut/lib/hosts";

export const metadata: Metadata = {
  title: "Install Donkey",
  description: "Download Donkey for macOS and install it with the standard drag-to-Applications flow.",
  alternates: { canonical: `${DONKEYCUT_CANONICAL}/install` },
};

// The install page lives on donkeycut.com (passed through by src/proxy.ts) and
// wears the Cut site's header and footer; every other host 404s. Local dev
// mirrors donkeycut.com.
export default async function InstallPage() {
  const host = (await headers()).get("host");
  if (!isDonkeycutHost(host) && !isLocalHost(host)) notFound();
  return (
    <main
      style={{
        minHeight: "100vh",
        background: BG,
        color: BLACK,
        fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
        WebkitFontSmoothing: "antialiased",
      }}
    >
      <CutTopNav root="" />
      <InstallInstructions />
      <CutFooter />
    </main>
  );
}
