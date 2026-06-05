import type { Metadata } from "next";

import { Footer } from "@/app/_components/landing/Footer";
import { TopNav } from "@/app/_components/landing/TopNav";
import { ApiSection } from "@/app/donkeyvision/ApiSection";
import { HeroSection } from "@/app/donkeyvision/HeroSection";
import { MediaSection } from "@/app/donkeyvision/MediaSection";
import { PricingSection } from "@/app/donkeyvision/PricingSection";
import { ProofSection } from "@/app/donkeyvision/ProofSection";
import { UseCasesSection } from "@/app/donkeyvision/UseCasesSection";
import { VisionCompareSection } from "@/app/donkeyvision/VisionCompareSection";

export const dynamic = "force-static";

export const metadata: Metadata = {
  title: "Donkey Vision | Donkey",
  description:
    "A low-latency API for detecting interactable UI elements in screenshots, with boxes, center points, and labels.",
};

export default function DonkeyVisionPage() {
  return (
    <main className="min-h-screen w-full overflow-x-hidden bg-[#F5EFE0] font-[-apple-system,BlinkMacSystemFont,'Segoe_UI',sans-serif] text-[#0F0E0D]">
      <TopNav ctaHref="#contact" ctaLabel="Contact us" />
      <HeroSection />
      <ProofSection />
      <ApiSection />
      <VisionCompareSection />
      <UseCasesSection />
      <MediaSection />
      <PricingSection />
      <Footer />
    </main>
  );
}
