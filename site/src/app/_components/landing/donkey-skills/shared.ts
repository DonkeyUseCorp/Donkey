import { cn } from "@/lib/utils";

// Tailwind class strings shared across the animated stages, kept in one place
// so the surfaces, captions, and stage widths stay consistent.
export const SURFACE =
  "relative w-full bg-white border-[1.5px] border-ink rounded-[10px] overflow-hidden shadow-[0_2px_0_0_rgba(0,0,0,0.12)]";
export const DOC_SURFACE = cn(SURFACE, "flex flex-col aspect-[612/792]");
export const CAP = "font-code text-xs text-coral min-h-4";
export const STAGE = "flex flex-col gap-3.5 w-full max-w-[740px] mx-auto";
export const STAGE_WIDE = "flex flex-col gap-3.5 w-full";
export const LEAD =
  "text-[clamp(16px,1.9vw,20px)] leading-[1.45] opacity-[0.82] m-0 max-w-[620px]";
export const GRID4 = "grid grid-cols-[1.2fr_1fr_1fr_1fr]";

export type StageProps = { reduceMotion: boolean };
export type DocStageProps = StageProps & { loop: boolean };
