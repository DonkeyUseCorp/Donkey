"use client";

import { ChevronLeft, ChevronRight } from "lucide-react";
import Image from "next/image";
import { useCallback, useRef, useState } from "react";

import { VisionOverlay } from "@/app/donkeyvision/VisionOverlay";
import type { VisionDataset } from "@/app/donkeyvision/visionData";

// Drag-to-reveal compare widget: left is the raw screenshot, right is the same
// pixels with detected controls boxed. Internal handle position resets whenever
// the component remounts, so callers can pass a changing `key` to reset it.
export function VisionCompareSlider({ dataset }: { dataset: VisionDataset }) {
  const [pos, setPos] = useState(50);
  const frameRef = useRef<HTMLDivElement>(null);
  const dragging = useRef(false);

  const moveTo = useCallback((clientX: number) => {
    const frame = frameRef.current;
    if (!frame) return;
    const rect = frame.getBoundingClientRect();
    const ratio = (clientX - rect.left) / rect.width;
    setPos(Math.min(100, Math.max(0, ratio * 100)));
  }, []);

  return (
    <div className="relative w-full max-w-full overflow-hidden rounded-lg border-2 border-[#0F0E0D] bg-[#FAF6EC]">
      <div className="flex items-center justify-between border-b-2 border-[#0F0E0D] bg-white px-4 py-[9px]">
        <div className="flex items-center gap-2">
          <span className="h-3 w-3 rounded-full border-2 border-[#0F0E0D] bg-[#EC7868]" />
          <span className="h-3 w-3 rounded-full border-2 border-[#0F0E0D] bg-[#F5D875]" />
          <span className="h-3 w-3 rounded-full border-2 border-[#0F0E0D] bg-[#B7E4C7]" />
        </div>
        <span className="text-[10px] font-semibold text-[#0F0E0D]">
          {dataset.title}
        </span>
      </div>

      <div
        ref={frameRef}
        className="relative w-full touch-none select-none"
        style={{ aspectRatio: `${dataset.width} / ${dataset.height}` }}
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
          src={dataset.image}
          alt={`${dataset.title} screenshot`}
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
          <VisionOverlay dataset={dataset} />
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
  );
}
