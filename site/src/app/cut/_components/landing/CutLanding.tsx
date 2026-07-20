"use client";

import { TopNav } from "@/app/_components/landing/TopNav";
import { BG, BLACK } from "@/app/_components/landing/theme";
import { CutFinalCTA } from "@/app/cut/_components/landing/CutFinalCTA";
import { CutFooter } from "@/app/cut/_components/landing/CutFooter";
import { CutHero } from "@/app/cut/_components/landing/CutHero";
import { CutOpenSource } from "@/app/cut/_components/landing/CutOpenSource";
import { CutPricing } from "@/app/cut/_components/landing/CutPricing";
import { CutWorksWith } from "@/app/cut/_components/landing/CutWorksWith";

// The donkeycut.com marketing page: the Donkey landing's cream visual system
// with Cut-only content. `root` is "" on donkeycut.com and "/cut" in dev, so
// links into the app resolve on either host. The nav carries no auth entry
// points — sign-in happens through the app's own surfaces (signInUrl) — while
// the signed-in "Go to App" pill points at the Cut projects home on either host.
export function CutLanding({ root }: { root: string }) {
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
      <TopNav
        homeHref={root || "/"}
        wordmark="Donkey Cut"
        signedInPill={{ href: `${root}/app`, label: "Go to App" }}
      />
      <CutHero root={root} />
      <CutWorksWith />
      <CutPricing root={root} />
      <CutOpenSource />
      <CutFinalCTA root={root} />
      <CutFooter />
    </main>
  );
}
