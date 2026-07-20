"use client";

import { TopNav } from "@/app/_components/landing/TopNav";
import { BG, BLACK } from "@/app/_components/landing/theme";
import { CutFinalCTA } from "@/app/cut/_components/landing/CutFinalCTA";
import { CutFooter } from "@/app/cut/_components/landing/CutFooter";
import { CutHero } from "@/app/cut/_components/landing/CutHero";
import { CutOpenSource } from "@/app/cut/_components/landing/CutOpenSource";
import { CutPricing } from "@/app/cut/_components/landing/CutPricing";

// The donkeycut.com marketing page: the Donkey landing's cream visual system
// with Cut-only content. `root` is "" on donkeycut.com and "/cut" in dev, so
// links into the app resolve on either host. Auth links are hidden: /sign-in
// does not exist on donkeycut.com — sign-in happens through the app's own
// entry points — while the signed-in Dashboard pill (→ /app) lands on the Cut
// projects home there.
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
      <TopNav homeHref={root || "/"} wordmark="Donkey Cut" showAuthLinks={false} />
      <CutHero root={root} />
      <CutPricing />
      <CutOpenSource />
      <CutFinalCTA root={root} />
      <CutFooter />
    </main>
  );
}
