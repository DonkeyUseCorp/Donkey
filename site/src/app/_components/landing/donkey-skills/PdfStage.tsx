"use client";

import { cn } from "@/lib/utils";
import { PDF_DETECT_COUNT, PDF_FILL, PDF_IMG, PDF_RECTS } from "./data";
import { CAP, STAGE, SURFACE, type StageProps } from "./shared";
import { usePhaseLoop } from "./usePhaseLoop";

// Fill any PDF: the real Form 1120 detects its fields, then maps values in.
export function PdfStage({ reduceMotion }: StageProps) {
  const fields = PDF_FILL.length;
  const total = fields + 2;
  const p = usePhaseLoop(total, { step: 330, reduceMotion });
  const detecting = p >= 1;
  const activeIdx = p - 2;
  const cap =
    p <= 0
      ? "Reading the books…"
      : p === 1
        ? `Detecting ${PDF_DETECT_COUNT} fields…`
        : p < total
          ? `Mapping → ${PDF_FILL[Math.min(activeIdx, fields - 1)].lab}`
          : "Form complete ✓";
  return (
    <div className={STAGE}>
      <div className={CAP}>{cap}</div>
      <div className={cn(SURFACE, "aspect-[612/792] [container-type:size]")}>
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img
          src={PDF_IMG}
          alt="IRS Form 1120, page 1"
          draggable={false}
          className="absolute inset-0 w-full h-full block object-fill select-none"
        />
        {detecting &&
          PDF_RECTS.map((r, i) => (
            <span
              key={`d${i}`}
              className="absolute border border-coral/55 bg-coral/[0.06] rounded-[1.5px] pointer-events-none animate-[donkey-detect-fade_0.3s_ease_both]"
              style={{ left: `${r[0]}%`, top: `${r[1]}%`, width: `${r[2]}%`, height: `${r[3]}%` }}
            />
          ))}
        {PDF_FILL.map((f, i) => {
          if (p < i + 2) return null;
          return (
            <span
              key={`f${i}`}
              className={cn(
                "absolute flex items-center pointer-events-none animate-[donkey-drop_0.28s_ease_both]",
                f.a === "r" ? "justify-end pr-[0.5cqh]" : "justify-start pl-[0.6cqh]",
                i === activeIdx && "bg-coral/[0.16] rounded-[2px] outline outline-[1.5px] outline-coral",
              )}
              style={{ left: `${f.l}%`, top: `${f.t}%`, width: `${f.w}%`, height: `${f.h}%` }}
            >
              <span className="font-semibold text-[1.25cqh] text-[#0b2a6b] whitespace-nowrap leading-none">
                {f.v}
              </span>
            </span>
          );
        })}
      </div>
    </div>
  );
}
