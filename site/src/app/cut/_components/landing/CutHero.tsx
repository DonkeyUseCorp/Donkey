"use client";

import { PillButton } from "@/app/_components/landing/LandingPrimitives";
import { EditorMock } from "@/app/cut/_components/landing/editor-mock/EditorMock";

export function CutHero({ root }: { root: string }) {
  return (
    <section
      id="top"
      className="mx-auto max-w-[1400px] px-6 pt-10 pb-20 md:px-12 md:pt-16 md:pb-[120px]"
    >
      <div>
        <h1 className="text-[clamp(36px,5.5vw,64px)] leading-[0.95] font-semibold tracking-[-0.02em]">
          Cut video with AI. <span className="italic">On your Mac.</span>
        </h1>
        <p className="mt-5 max-w-[720px] text-[16px] leading-[1.55] text-[#454545] md:text-[17px]">
          A video editor with generation built into the timeline: images,
          clips, voiceover, and music appear where you ask for them. Editing
          and export run on your own Mac.
        </p>
        <div className="mt-8">
          <PillButton href={`${root}/app`} variant="primary" size="md">
            Start a new project
          </PillButton>
        </div>
      </div>
      <div className="mt-12 md:mt-16">
        <EditorMock />
      </div>
    </section>
  );
}
