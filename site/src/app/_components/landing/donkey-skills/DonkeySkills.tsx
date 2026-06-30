"use client";

import { Plus } from "lucide-react";
import { useEffect, useState } from "react";

import { cn } from "@/lib/utils";
import { useMediaQuery } from "@/app/_components/landing/useMediaQuery";
import { DeckStage } from "./DeckStage";
import { DocStage } from "./DocStage";
import { PdfStage } from "./PdfStage";
import { VideoStage } from "./VideoStage";
import { SKILLS, TEACH, type DocType, type SkillKind } from "./data";
import { LEAD } from "./shared";
import "./styles.css";

function Stage({ kind, reduceMotion }: { kind: SkillKind; reduceMotion: boolean }) {
  if (kind === "pdf") return <PdfStage reduceMotion={reduceMotion} />;
  if (kind === "deck") return <DeckStage reduceMotion={reduceMotion} />;
  return <VideoStage />;
}

const DOC_ORDER: DocType[] = ["sheet", "word", "pdf"];
const DOC_DWELL: Record<DocType, number> = { sheet: 4200, word: 5400, pdf: 5000 };
const DOC_TABS: [DocType, string][] = [
  ["sheet", "Spreadsheet"],
  ["word", "Word"],
  ["pdf", "PDF"],
];

const CHIP =
  "shrink-0 whitespace-nowrap cursor-pointer inline-flex items-center gap-2 border-2 border-ink rounded-full font-bold text-sm px-4 py-[9px] [scroll-snap-align:start] transition-[transform,background] duration-150 hover:-translate-y-px focus-visible:outline focus-visible:outline-[3px] focus-visible:outline-coral focus-visible:outline-offset-2";

export function DonkeySkills() {
  const reduceMotion = useMediaQuery("(prefers-reduced-motion: reduce)");
  const [active, setActive] = useState(0);
  const [docType, setDocType] = useState<DocType>("sheet");
  const [docAuto, setDocAuto] = useState(true);
  const isTeach = active === SKILLS.length;
  const skill = isTeach ? null : SKILLS[active];

  useEffect(() => {
    if (!skill || skill.kind !== "doc" || !docAuto || reduceMotion) return;
    const t = setTimeout(() => {
      setDocType((d) => DOC_ORDER[(DOC_ORDER.indexOf(d) + 1) % DOC_ORDER.length]);
    }, DOC_DWELL[docType]);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [active, docType, docAuto, reduceMotion]);

  const pickDoc = (k: DocType) => {
    setDocAuto(false);
    setDocType(k);
  };

  return (
    <div className="font-system mt-10 md:mt-14">
      <div
        className="flex gap-2.5 overflow-x-auto pt-1 px-0.5 pb-3.5 mb-[22px] [scroll-snap-type:x_proximity] [-webkit-overflow-scrolling:touch] [&::-webkit-scrollbar]:h-0"
        role="tablist"
        aria-label="Donkey skills"
      >
        {SKILLS.map((s, idx) => (
          <button
            key={s.name}
            role="tab"
            aria-selected={active === idx}
            className={cn(CHIP, "text-ink", active === idx ? "bg-coral" : "bg-cream")}
            onClick={() => setActive(idx)}
          >
            {s.name}
          </button>
        ))}
        <button
          role="tab"
          aria-selected={isTeach}
          className={cn(CHIP, "border-dashed", isTeach ? "bg-ink text-cream border-solid" : "bg-transparent text-ink")}
          onClick={() => setActive(SKILLS.length)}
        >
          <Plus size={16} strokeWidth={3} />
          Teach a skill
        </button>
      </div>

      <div
        key={active}
        className="border-2 border-ink rounded-[22px] bg-cream p-[clamp(20px,3vw,34px)] shadow-[5px_5px_0_0_#0f0e0d] animate-[donkey-pop_0.28s_ease_both]"
      >
        {!skill ? (
          <div className="px-0.5 py-1.5">
            <h3 className="text-[clamp(24px,3vw,34px)] font-extrabold tracking-[-0.02em] m-0">{TEACH.name}</h3>
            <p className="text-[clamp(15px,1.7vw,19px)] mt-1.5 opacity-[0.78]">{TEACH.promise}</p>
            <p className="text-[clamp(15px,1.8vw,18px)] leading-[1.55] max-w-[620px] mt-[18px] mb-[22px] opacity-[0.85]">
              {TEACH.body}
            </p>
            <div className="inline-block font-code text-xs border-[1.5px] border-ink rounded-full px-3.5 py-[7px] bg-[#F6DD8C]">
              record once · replays free
            </div>
          </div>
        ) : (
          <div className="flex flex-col gap-[18px]">
            {skill.kind === "doc" ? (
              <>
                <div className="flex justify-between items-center gap-x-5 gap-y-3.5 flex-wrap">
                  <p className={LEAD}>{skill.promise}</p>
                  <div className="flex gap-1 flex-wrap" role="tablist" aria-label="Document type">
                    {DOC_TABS.map(([k, label]) => (
                      <button
                        key={k}
                        role="tab"
                        aria-selected={docType === k}
                        className={cn(
                          "appearance-none border-none bg-transparent text-ink font-bold text-sm px-[15px] py-[7px] rounded-full cursor-pointer transition-[background,opacity] duration-150 focus-visible:outline focus-visible:outline-2 focus-visible:outline-ink focus-visible:outline-offset-2",
                          docType === k ? "opacity-100 bg-coral" : "opacity-50 hover:opacity-100 hover:bg-[#FCEAE3]",
                        )}
                        onClick={() => pickDoc(k)}
                      >
                        {label}
                      </button>
                    ))}
                  </div>
                </div>
                <DocStage docType={docType} reduceMotion={reduceMotion} loop={!docAuto} />
              </>
            ) : (
              <>
                <p className={LEAD}>{skill.promise}</p>
                <Stage kind={skill.kind} reduceMotion={reduceMotion} />
              </>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
