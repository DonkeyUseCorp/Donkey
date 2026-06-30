"use client";

import { useState } from "react";

import { VisionCompareSlider } from "@/app/donkeyvision/VisionCompareSlider";
import { VISION_DATASETS } from "@/app/donkeyvision/visionData";

export function VisionCompareSection() {
  const [activeKey, setActiveKey] = useState(VISION_DATASETS[0].key);

  const active =
    VISION_DATASETS.find((d) => d.key === activeKey) ?? VISION_DATASETS[0];

  return (
    <section
      id="demo"
      className="border-y-2 border-[#0F0E0D] bg-[#F5EFE0] py-20"
    >
      <div className="mx-auto max-w-[1400px] px-6 md:px-12">
        <h2 className="max-w-3xl text-4xl font-semibold leading-none md:text-6xl">
          Drag to see what it reads.
        </h2>
        <p className="mt-6 max-w-2xl text-lg leading-8 text-[#454545]">
          Left is the raw screenshot. Right is the same pixels with every
          detected control boxed and labeled. Drag the handle — no DOM, no
          integration, just the image.
        </p>

        <div className="relative mt-10">
          <VisionCompareSlider key={active.key} dataset={active} />
        </div>

        {/* Dataset buttons. */}
        <div className="mt-6 flex flex-wrap gap-3">
          {VISION_DATASETS.map((d) => {
            const isActive = d.key === active.key;
            return (
              <button
                key={d.key}
                type="button"
                onClick={() => setActiveKey(d.key)}
                aria-pressed={isActive}
                className={`rounded-md border-2 border-[#0F0E0D] px-5 py-2.5 text-sm font-semibold transition-colors ${
                  isActive
                    ? "bg-[#0F0E0D] text-white"
                    : "bg-white text-[#0F0E0D] hover:bg-[#F5D875]"
                }`}
              >
                {d.title}
              </button>
            );
          })}
        </div>
      </div>
    </section>
  );
}
