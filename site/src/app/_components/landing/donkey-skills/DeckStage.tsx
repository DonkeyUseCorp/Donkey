"use client";

import { ChevronLeft, ChevronRight } from "lucide-react";
import { useEffect, useState } from "react";

import { cn } from "@/lib/utils";
import { DECK_SLIDES } from "./data";
import { STAGE_WIDE, type StageProps } from "./shared";

// Design the deck: each slide is a finished mini-poster; only content animates.
const SL_BASE =
  "flex-1 flex flex-col min-h-0 py-[6.5%] px-[7.5%] [&>*]:animate-[donkey-slide-in_0.42s_ease_both] [&>*:nth-child(2)]:[animation-delay:0.07s] [&>*:nth-child(3)]:[animation-delay:0.14s] [&>*:nth-child(4)]:[animation-delay:0.21s]";
const SL_H = "text-[6.6cqw] font-black tracking-[-0.025em] mb-[5%]";

function Slide({ i }: { i: number }) {
  if (i === 0) {
    return (
      <div className={cn(SL_BASE, "bg-[#17141F] text-[#F6EEE7] justify-center items-start text-left")}>
        <div className="font-code text-[2.4cqw] tracking-[0.22em] uppercase text-[#FB8B6E] mb-[3%]">
          Pitch deck · 2026
        </div>
        <h3 className="text-[21cqw] font-black tracking-[-0.045em] leading-[0.82] m-0 text-white">Donkey</h3>
        <div className="w-[14%] h-[5px] bg-coral my-[4.5%] rounded-[2px]" />
        <p className="text-[4.6cqw] m-0 font-medium text-[#D8D0E4]">
          Get work done <em className="text-[#FB8B6E]">while you sleep.</em>
        </p>
      </div>
    );
  }
  if (i === 1) {
    return (
      <div className={cn(SL_BASE, "bg-[#F3EDDF] text-ink justify-center")}>
        <div className="font-code text-[2.8cqw] tracking-[0.16em] uppercase text-[#C8472B] mb-[1%]">
          The busywork tax
        </div>
        <div className="text-[30cqw] font-black leading-[0.8] tracking-[-0.05em]">
          2<span className="text-[9cqw] text-coral ml-[1.5%]">hrs</span>
        </div>
        <p className="text-[4cqw] max-w-[68%] mt-[3.5%] opacity-[0.82] leading-[1.32]">
          lost to manual, repetitive work every single day — per person.
        </p>
      </div>
    );
  }
  if (i === 2) {
    const cols: [string, string, string, string, string][] = [
      ["01", "Ask", "Double-tap ⌘ and say the task.", "border-t-coral", "text-coral"],
      ["02", "Watch", "It drives your apps on your Mac.", "border-t-[#4C5BD4]", "text-[#4C5BD4]"],
      ["03", "Approve", "You sign off on the result.", "border-t-[#1FA98C]", "text-[#1FA98C]"],
    ];
    return (
      <div className={cn(SL_BASE, "bg-white text-ink")}>
        <h4 className={SL_H}>Ask. Watch. Approve.</h4>
        <div className="grid grid-cols-3 gap-[5%] flex-1">
          {cols.map(([n, w, t, border, num]) => (
            <div key={n} className={cn("flex flex-col border-t-4 pt-[4%]", border)}>
              <span className={cn("font-code text-[3.4cqw] font-bold", num)}>{n}</span>
              <span className="text-[5.2cqw] font-extrabold my-[3%]">{w}</span>
              <span className="text-[3.2cqw] leading-[1.34] opacity-[0.78]">{t}</span>
            </div>
          ))}
        </div>
      </div>
    );
  }
  if (i === 3) {
    const bars = [4, 6, 7, 9, 11];
    return (
      <div className={cn(SL_BASE, "bg-[#EDEFFb] text-ink")}>
        <h4 className={SL_H}>Hours back, per week</h4>
        <div className="flex-1 flex items-end gap-[4.5%] pt-[3%] pb-[2%]">
          {bars.map((v, k) => (
            <div
              key={k}
              className={cn(
                "flex-1 border-2 border-ink rounded-t-[6px] flex justify-center items-start min-h-[8%]",
                k === bars.length - 1 ? "bg-coral" : "bg-[#4C5BD4]",
              )}
              style={{ height: `${(v / 11) * 100}%` }}
            >
              <span className="font-code text-[3cqw] font-bold text-white pt-[4%]">{v}h</span>
            </div>
          ))}
        </div>
        <div className="flex gap-[4.5%]">
          {["Wk 1", "Wk 2", "Wk 3", "Wk 4", "Wk 5"].map((w) => (
            <span key={w} className="flex-1 text-center font-code text-[2.6cqw] opacity-[0.55]">
              {w}
            </span>
          ))}
        </div>
      </div>
    );
  }
  return (
    <div className={cn(SL_BASE, "bg-coral text-ink justify-center items-center text-center")}>
      <h3 className="text-[9.2cqw] font-black tracking-[-0.03em] leading-[1.02] mb-[5%]">
        Every Mac needs a <em className="text-white">Donkey.</em>
      </h3>
      <div className="bg-ink text-white border-2 border-ink rounded-full font-extrabold text-[3.9cqw] px-[6.5%] py-[2.8%]">
        Download for Mac
      </div>
      <div className="font-code text-[3cqw] mt-[3.5%] opacity-[0.7]">donkeyuse.com</div>
    </div>
  );
}

export function DeckStage({ reduceMotion }: StageProps) {
  const count = DECK_SLIDES.length;
  const [i, setI] = useState(0);
  const [auto, setAuto] = useState(true);
  useEffect(() => {
    if (!auto || reduceMotion) return;
    const t = setTimeout(() => setI((v) => (v + 1) % count), 3600);
    return () => clearTimeout(t);
  }, [i, auto, reduceMotion, count]);
  const go = (n: number) => {
    setAuto(false);
    setI((n + count) % count);
  };
  const chev =
    "absolute top-1/2 -translate-y-1/2 z-[5] w-[42px] h-[42px] rounded-full border-2 border-ink bg-white/90 text-ink cursor-pointer flex items-center justify-center shadow-[2px_2px_0_0_rgba(0,0,0,0.25)] transition-[background,transform] duration-150 hover:bg-coral hover:scale-[1.06] focus-visible:outline focus-visible:outline-[3px] focus-visible:outline-coral focus-visible:outline-offset-2";
  return (
    <div className={STAGE_WIDE}>
      <div className="flex flex-col gap-3">
        <div className="relative">
          <button className={cn(chev, "left-[14px]")} onClick={() => go(i - 1)} aria-label="Previous slide">
            <ChevronLeft size={24} strokeWidth={2.5} />
          </button>
          <div className="w-full">
            <div className="[container-type:size] aspect-[16/9] border-2 border-ink rounded-[14px] shadow-[4px_4px_0_0_#0f0e0d] overflow-hidden flex bg-white">
              <Slide key={i} i={i} />
            </div>
          </div>
          <button className={cn(chev, "right-[14px]")} onClick={() => go(i + 1)} aria-label="Next slide">
            <ChevronRight size={24} strokeWidth={2.5} />
          </button>
        </div>
        <div className="flex gap-2.5" role="tablist" aria-label="Slides">
          {DECK_SLIDES.map((s, k) => (
            <button
              key={k}
              role="tab"
              aria-selected={k === i}
              className={cn(
                "relative flex-1 min-w-0 aspect-[16/9] border-[1.5px] border-ink rounded-[7px] cursor-pointer flex items-center justify-center px-3 overflow-hidden transition-[background,transform] duration-150 hover:-translate-y-px hover:bg-[#FCEAE3] focus-visible:outline focus-visible:outline-2 focus-visible:outline-coral focus-visible:outline-offset-2",
                k === i ? "bg-[#FCEAE3] border-2 border-coral" : "bg-cream",
              )}
              onClick={() => go(k)}
            >
              <span className="absolute bottom-1.5 right-[9px] font-code text-[10px] opacity-50">
                {String(k + 1).padStart(2, "0")}
              </span>
              <span className="text-[11px] font-bold leading-[1.15] text-center whitespace-nowrap overflow-hidden text-ellipsis max-w-full">
                {s.label}
              </span>
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}
