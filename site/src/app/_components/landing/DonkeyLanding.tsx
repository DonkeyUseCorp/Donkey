"use client";

import { Demo } from "@/app/_components/landing/Demo";
import { DonkeyVisionCTA } from "@/app/_components/landing/DonkeyVisionCTA";
import { FinalCTA } from "@/app/_components/landing/FinalCTA";
import { Footer } from "@/app/_components/landing/Footer";
import { Hero } from "@/app/_components/landing/Hero";
import { OpenSource } from "@/app/_components/landing/OpenSource";
import { Pricing } from "@/app/_components/landing/Pricing";
import { Solutions } from "@/app/_components/landing/Solutions";
import { TopNav } from "@/app/_components/landing/TopNav";
import { TrustedBy } from "@/app/_components/landing/TrustedBy";
import { BG, BLACK } from "@/app/_components/landing/theme";

export default function DonkeyLanding() {
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
      <TopNav />
      <Hero />
      <TrustedBy />
      <Solutions />
      <Demo />
      <OpenSource />
      <Pricing />
      <DonkeyVisionCTA />
      <FinalCTA />
      <Footer />
    </main>
  );
}
