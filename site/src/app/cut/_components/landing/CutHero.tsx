"use client";

import { ArrowRight } from "lucide-react";

import { PillButton } from "@/app/_components/landing/LandingPrimitives";
import { DONKEY_INSTALL_URL } from "@/app/_components/landing/data";
import { EditorMock } from "@/app/cut/_components/landing/editor-mock/EditorMock";

export function CutHero({ root }: { root: string }) {
  return (
    <section
      id="top"
      className="mx-auto max-w-[1400px] px-6 pt-8 pb-20 md:px-12 md:pt-16 md:pb-[120px]"
    >
      <h1 className="text-[clamp(45px,8vw,110px)] leading-[0.88] font-semibold tracking-[-0.03em]">
        Cut video with AI.
        <br />
        <span className="italic">On your Mac.</span>
      </h1>
      <p className="mt-8 max-w-[640px] text-[18px] leading-[1.55] text-[#454545] md:max-w-[900px] md:text-[20px]">
        Donkey Cut is a video editor with generation built into the timeline:
        images, clips, voiceover, and music appear where you ask for them.
        Editing and export run on your own Mac.
      </p>
      <div className="mt-9 flex flex-wrap gap-3">
        <PillButton href={DONKEY_INSTALL_URL} variant="primary" size="lg">
          Download for Mac <ArrowRight size={18} />
        </PillButton>
        <PillButton href={`${root}/app`} variant="secondary" size="lg">
          Open the editor
        </PillButton>
      </div>
      <div className="mt-14 md:mt-20">
        <EditorMock />
      </div>
    </section>
  );
}
