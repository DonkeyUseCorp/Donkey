"use client";

import { Demo } from "@/app/_components/landing/Demo";
import { DonkeyVisionCTA } from "@/app/_components/landing/DonkeyVisionCTA";
import { FinalCTA } from "@/app/_components/landing/FinalCTA";
import { Footer } from "@/app/_components/landing/Footer";
import { Hero } from "@/app/_components/landing/Hero";
import { MediaShowcase } from "@/app/_components/landing/media-showcase/MediaShowcase";
import { OpenSource } from "@/app/_components/landing/OpenSource";
import { Pricing } from "@/app/_components/landing/Pricing";
import { Solutions } from "@/app/_components/landing/Solutions";
import { TopNav } from "@/app/_components/landing/TopNav";
import { TrustedBy } from "@/app/_components/landing/TrustedBy";
import { UseCasesOverview } from "@/app/_components/landing/UseCasesOverview";
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
      <MediaShowcase
        blurb="Generate images and video with Gemini and Veo — then keep going with motion graphics, UGC, and more. Click any example to reveal its prompt and copy it straight into Donkey."
        heading="Media Donkey can make"
        limit={10}
        viewAllHref="/use-cases"
      />
      <UseCasesOverview />
      <Demo />
      <OpenSource />
      <Pricing />
      <DonkeyVisionCTA />
      <FinalCTA />
      <Footer />
    </main>
  );
}
