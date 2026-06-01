"use client";

import { ArrowRight, Boxes, Crosshair, Gauge } from "lucide-react";

import {
  Headline,
  PillButton,
} from "@/app/_components/landing/LandingPrimitives";

const points = [
  {
    icon: Boxes,
    text: "Detect interactable elements from screenshots.",
  },
  {
    icon: Crosshair,
    text: "Ground requests like find the play button or find the next button.",
  },
  {
    icon: Gauge,
    text: "Built for low-latency agent loops.",
  },
];

export function DonkeyVisionCTA() {
  return (
    <section className="mx-auto box-border w-full max-w-[1400px] px-6 py-20 md:px-12 md:py-24">
      <div className="relative">
        <div className="absolute inset-0 translate-x-2 translate-y-2 rounded-2xl bg-[#A8D5E8]" />
        <div className="relative grid gap-8 rounded-2xl border-2 border-[#0F0E0D] bg-[#0F0E0D] p-8 text-white md:grid-cols-[minmax(0,1fr)_minmax(320px,0.56fr)] md:p-12">
          <div className="min-w-0">
            <div className="mb-5 inline-flex w-fit rounded-md bg-white px-3 py-2 text-xs font-semibold uppercase tracking-[0.12em] text-[#0F0E0D]">
              Donkey Vision API
            </div>
            <Headline size="lg">
              Building computer-use agents?
            </Headline>
            <p className="mt-6 max-w-2xl text-lg leading-8 text-white/75">
              Give your agent a fast, structured map of any software screenshot.
              Donkey Vision returns elements, boxes, labels, and target points so
              your application can reason about the screen without brittle DOM
              access or app-specific integrations.
            </p>
            <div className="mt-8 flex flex-wrap gap-3">
              <PillButton href="/donkeyvision" variant="primary" size="lg">
                Explore Donkey Vision <ArrowRight size={18} />
              </PillButton>
              <PillButton
                href="mailto:david@donkeyuse.com?subject=Donkey%20Vision%20API"
                variant="secondary"
                size="lg"
              >
                Contact us
              </PillButton>
            </div>
          </div>
          <div className="grid content-center gap-4">
            {points.map((point) => {
              const Icon = point.icon;

              return (
                <div
                  className="flex items-start gap-4 rounded-lg border-2 border-white/20 bg-white p-4 text-[#0F0E0D]"
                  key={point.text}
                >
                  <div className="flex h-11 w-11 shrink-0 items-center justify-center rounded-md border-2 border-[#0F0E0D] bg-[#F5D875]">
                    <Icon size={20} aria-hidden="true" />
                  </div>
                  <p className="m-0 text-sm font-semibold leading-6">
                    {point.text}
                  </p>
                </div>
              );
            })}
          </div>
        </div>
      </div>
    </section>
  );
}
