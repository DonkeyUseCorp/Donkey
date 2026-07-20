"use client";

import { ArrowRight } from "lucide-react";

import { PillButton } from "@/app/_components/landing/LandingPrimitives";
import { DONKEY_INSTALL_URL } from "@/app/_components/landing/data";
import { EditorMock } from "@/app/cut/_components/landing/editor-mock/EditorMock";

export function CutHero({ root }: { root: string }) {
  return (
    <section
      id="top"
      className="mx-auto max-w-[1400px] px-6 pt-4 pb-20 md:px-12 md:pt-6 md:pb-[120px]"
    >
      <div className="flex flex-col items-start gap-5 md:flex-row md:items-end md:justify-between md:gap-8">
        <div>
          <h1 className="text-[clamp(32px,3.6vw,52px)] leading-[0.95] font-semibold tracking-[-0.02em]">
            Cut video with AI. <span className="italic">On your Mac.</span>
          </h1>
          <p className="mt-4 max-w-[720px] text-[16px] leading-[1.5] text-[#454545] md:text-[17px]">
            A video editor with generation built into the timeline: images,
            clips, voiceover, and music appear where you ask for them. Editing
            and export run on your own Mac.
          </p>
        </div>
        <div className="flex shrink-0 flex-wrap gap-3">
          <PillButton href={DONKEY_INSTALL_URL} variant="primary" size="md">
            Download for Mac <ArrowRight size={16} />
          </PillButton>
          <PillButton href={`${root}/app`} variant="secondary" size="md">
            Open the editor
          </PillButton>
        </div>
      </div>
      <div className="mt-8 md:mt-10">
        <EditorMock />
      </div>
    </section>
  );
}
