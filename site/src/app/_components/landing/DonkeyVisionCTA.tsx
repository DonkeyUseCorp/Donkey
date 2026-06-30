"use client";

import {
  Headline,
  PillButton,
} from "@/app/_components/landing/LandingPrimitives";
import { VisionCompareSlider } from "@/app/donkeyvision/VisionCompareSlider";
import { VISION_DATASETS } from "@/app/donkeyvision/visionData";

const spotify =
  VISION_DATASETS.find((d) => d.key === "spotify") ?? VISION_DATASETS[0];

export function DonkeyVisionCTA() {
  return (
    <section className="mx-auto box-border w-full max-w-[1400px] px-6 py-20 md:px-12 md:py-24">
      <div className="relative">
        <div className="absolute inset-0 translate-x-2 translate-y-2 rounded-2xl bg-[#A8D5E8]" />
        <div className="relative grid gap-8 rounded-2xl border-2 border-[#0F0E0D] bg-[#0F0E0D] p-8 text-white md:grid-cols-[minmax(0,1fr)_minmax(320px,0.56fr)] md:p-12">
          <div className="min-w-0">
            <Headline size="lg">Building computer-use agents?</Headline>
            <p className="mt-6 max-w-2xl text-lg leading-8 text-white/75">
              Give your agent a fast, structured map of any software screenshot.
              Donkey Vision returns elements, boxes, labels, and target points so
              your application can reason about the screen without brittle DOM
              access or app-specific integrations.
            </p>
            <div className="mt-8 flex flex-wrap gap-3">
              <PillButton href="/donkeyvision" variant="secondary" size="lg">
                Explore Donkey Vision
              </PillButton>
            </div>
          </div>
          <div className="grid content-center gap-3">
            <VisionCompareSlider dataset={spotify} />
            <p className="m-0 text-center text-xs font-medium text-white/60">
              Drag to compare — raw screenshot vs. detected controls.
            </p>
          </div>
        </div>
      </div>
    </section>
  );
}
