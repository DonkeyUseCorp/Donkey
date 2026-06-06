"use client";

import { ChevronLeft, ChevronRight } from "lucide-react";
import Image from "next/image";
import { useCallback, useRef, useState } from "react";

import {
  VISION_DATASETS,
  type VisionDataset,
} from "@/app/donkeyvision/visionData";

// Per-index palette (matches the worker overlay + the Mac app's vision overlay),
// so adjacent boxes read apart instead of sharing one color.
const PALETTE = [
  "#FF3B30", "#FF9500", "#FFCC00", "#34C759",
  "#00C7BE", "#30B0C7", "#007AFF", "#5856D6",
  "#AF52DE", "#FF2D55", "#A2845E", "#8E8E93",
];

function textOn(hex: string): string {
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  return 0.299 * r + 0.587 * g + 0.114 * b > 150 ? "#0F0E0D" : "#FFFFFF";
}

function Overlay({ dataset }: { dataset: VisionDataset }) {
  const { width: W, height: H, elements } = dataset;
  const fs = W / 85;
  return (
    <svg
      className="absolute inset-0 h-full w-full"
      viewBox={`0 0 ${W} ${H}`}
      preserveAspectRatio="none"
      aria-hidden="true"
    >
      {elements.map((el, i) => {
        const color = PALETTE[i % PALETTE.length];
        const x = el.box[0] * W;
        const y = el.box[1] * H;
        const w = (el.box[2] - el.box[0]) * W;
        const h = (el.box[3] - el.box[1]) * H;
        const text = `AI ${el.label}`.slice(0, 26);
        const chipH = fs + 5;
        const chipW = text.length * fs * 0.56 + 6;
        const chipY = y - chipH >= 0 ? y - chipH : y;
        return (
          <g key={i}>
            <rect
              x={x}
              y={y}
              width={w}
              height={h}
              fill="none"
              stroke={color}
              strokeWidth={2}
              vectorEffect="non-scaling-stroke"
            />
            <rect x={x} y={chipY} width={chipW} height={chipH} fill={color} />
            <text
              x={x + 3}
              y={chipY + chipH - 4}
              fontSize={fs}
              fontFamily="-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"
              fontWeight={600}
              fill={textOn(color)}
            >
              {text}
            </text>
          </g>
        );
      })}
    </svg>
  );
}

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
      className="border-y-2 border-[#0F0E0D] bg-[#F5EFE0] px-6 py-20 md:px-12"
    >
      <div className="mx-auto max-w-[1100px]">
        <h2 className="max-w-3xl text-4xl font-semibold leading-none md:text-6xl">
          Drag to see what it reads.
        </h2>
        <p className="mt-6 max-w-2xl text-lg leading-8 text-[#454545]">
          Left is the raw screenshot. Right is the same pixels with every
          detected control boxed and labeled. Drag the handle — no DOM, no
          integration, just the image.
        </p>

        <div className="relative mt-10">
          <div className="absolute inset-0 translate-x-2 translate-y-2 rounded-lg bg-[#0F0E0D]" />
          <div className="relative overflow-hidden rounded-lg border-2 border-[#0F0E0D] bg-[#FAF6EC]">
            <div className="flex items-center justify-between border-b-2 border-[#0F0E0D] bg-white px-4 py-3">
              <div className="flex items-center gap-2">
                <span className="h-3 w-3 rounded-full border-2 border-[#0F0E0D] bg-[#EC7868]" />
                <span className="h-3 w-3 rounded-full border-2 border-[#0F0E0D] bg-[#F5D875]" />
                <span className="h-3 w-3 rounded-full border-2 border-[#0F0E0D] bg-[#B7E4C7]" />
              </div>
              <span className="text-sm font-semibold">{active.title}</span>
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
                <Overlay dataset={active} />
              </div>

              <span className="absolute left-3 top-3 rounded border-2 border-[#0F0E0D] bg-white px-2 py-1 text-xs font-semibold">
                Original
              </span>
              <span className="absolute right-3 top-3 rounded border-2 border-[#0F0E0D] bg-[#0F0E0D] px-2 py-1 text-xs font-semibold text-white">
                AI overlay
              </span>

              {/* Divider + handle. */}
              <div
                className="absolute inset-y-0 w-0.5 -translate-x-1/2 bg-[#0F0E0D]"
                style={{ left: `${pos}%` }}
              >
                <div className="absolute top-1/2 left-1/2 flex h-10 w-10 -translate-x-1/2 -translate-y-1/2 items-center justify-center rounded-full border-2 border-[#0F0E0D] bg-white shadow-[2px_2px_0_0_#0F0E0D]">
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
                <span className="ml-2 font-mono text-xs opacity-70">
                  {d.elements.length}
                </span>
              </button>
            );
          })}
        </div>
      </div>
    </section>
  );
}
