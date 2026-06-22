"use client";

import { ChevronLeft, ChevronRight } from "lucide-react";
import Image from "next/image";
import { useCallback, useRef, useState } from "react";

import { VisionOverlay } from "@/app/donkeyvision/VisionOverlay";
import { VISION_DATASETS } from "@/app/donkeyvision/visionData";

export function VisionCompareSection() {
  const [activeKey, setActiveKey] = useState(VISION_DATASETS[0].key);
  const [pos, setPos] = useState(50);
  const frameRef = useRef<HTMLDivElement>(null);
  const dragging = useRef(false);

  const active =
    VISION_DATASETS.find((d) => d.key === activeKey) ?? VISION_DATASETS[0];

  const moveTo = useCallback((clientX: number) => {
    const frame = frameRef.current;
    if (!frame) return;
    const rect = frame.getBoundingClientRect();
    const ratio = (clientX - rect.left) / rect.width;
    setPos(Math.min(100, Math.max(0, ratio * 100)));
  }, []);

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
          <div className="relative overflow-hidden rounded-lg border-2 border-[#0F0E0D] bg-[#FAF6EC]">
            <div className="flex items-center justify-between border-b-2 border-[#0F0E0D] bg-white px-4 py-[9px]">
              <div className="flex items-center gap-2">
                <span className="h-3 w-3 rounded-full border-2 border-[#0F0E0D] bg-[#EC7868]" />
                <span className="h-3 w-3 rounded-full border-2 border-[#0F0E0D] bg-[#F5D875]" />
                <span className="h-3 w-3 rounded-full border-2 border-[#0F0E0D] bg-[#B7E4C7]" />
              </div>
              <span className="text-[10px] font-semibold">{active.title}</span>
            </div>

            <div
              ref={frameRef}
              className="relative w-full touch-none select-none"
              style={{ aspectRatio: `${active.width} / ${active.height}` }}
              onPointerDown={(e) => {
                dragging.current = true;
                e.currentTarget.setPointerCapture(e.pointerId);
                moveTo(e.clientX);
              }}
              onPointerMove={(e) => {
                if (dragging.current) moveTo(e.clientX);
              }}
              onPointerUp={() => {
                dragging.current = false;
              }}
            >
              <Image
                src={active.image}
                alt={`${active.title} screenshot`}
                fill
                draggable={false}
                sizes="(max-width: 1100px) 100vw, 1100px"
                className="object-cover"
              />
              {/* Reveal the overlay only to the right of the handle. */}
              <div
                className="absolute inset-0"
                style={{ clipPath: `inset(0 0 0 ${pos}%)` }}
              >
                <VisionOverlay dataset={active} />
              </div>

              {/* Divider + handle. */}
              <div
                className="absolute inset-y-0 w-0.5 -translate-x-1/2 bg-[#007AFF]"
                style={{ left: `${pos}%` }}
              >
                <div className="absolute top-1/2 left-1/2 flex h-10 w-10 -translate-x-1/2 -translate-y-1/2 items-center justify-center rounded-full border-2 border-[#007AFF] bg-white">
                  <ChevronLeft size={16} aria-hidden="true" />
                  <ChevronRight size={16} aria-hidden="true" />
                </div>
              </div>
            </div>
          </div>
        </div>

        {/* Dataset buttons. */}
        <div className="mt-6 flex flex-wrap gap-3">
          {VISION_DATASETS.map((d) => {
            const isActive = d.key === active.key;
            return (
              <button
                key={d.key}
                type="button"
                onClick={() => {
                  setActiveKey(d.key);
                  setPos(50);
                }}
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
