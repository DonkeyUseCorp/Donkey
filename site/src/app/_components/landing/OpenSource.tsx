"use client";

import {
  Headline,
  PillButton,
  TapedCard,
} from "@/app/_components/landing/LandingPrimitives";
import { GITHUB_REPO_URL, openSourceReasons } from "@/app/_components/landing/data";

export function OpenSource() {
  return (
    <section className="mx-auto max-w-[1400px] px-6 py-20 md:px-12 md:py-24">
      <Headline>
        Donkey is <span className="italic">open source.</span>
      </Headline>
      <p className="mt-6 max-w-[900px] text-[17px] leading-[1.55] text-[#454545]">
        Donkey is built in the open. Read the source, host it yourself,
        contribute and make it better.
      </p>

      <div className="mt-8">
        <TapedCard color="cream" shadowColor="coral" tapeColor="coral">
          <div className="p-6 md:p-10">
            <div className="overflow-x-auto rounded-xl bg-ink px-[18px] py-5 font-code text-[13px] text-white md:p-6 md:text-[15px]">
              <div className="mb-4 flex items-center gap-2 text-[#888]">
                <span className="h-[10px] w-[10px] rounded-full bg-[#FF5F57]" />
                <span className="h-[10px] w-[10px] rounded-full bg-[#FEBC2E]" />
                <span className="h-[10px] w-[10px] rounded-full bg-[#28C840]" />
                <span className="ml-2 text-xs">
                  ~/ - DonkeyUseCorp/Donkey
                </span>
              </div>
              <div className="whitespace-nowrap text-[#b7b7b7]">
                <span className="text-[#5FFFB9]">$</span> git clone{" "}
                {GITHUB_REPO_URL}
              </div>
              <div className="mt-3 text-[#6f6f6f]">
                # Compile and run the macOS app
              </div>
              <div className="mt-1 whitespace-nowrap text-[#b7b7b7]">
                <span className="text-[#5FFFB9]">$</span> cd
                Donkey/apps/Donkey && swift run Donkey
              </div>
              <div className="mt-3 text-[#6f6f6f]">
                # Or run the server yourself
              </div>
              <div className="mt-1 whitespace-nowrap text-[#b7b7b7]">
                <span className="text-[#5FFFB9]">$</span> cd Donkey/site &&
                npm install && npm run dev
              </div>
              <div className="mt-3 text-[#5FFFB9]">
                Server running - http://localhost:3000
              </div>
            </div>

            <div className="mt-6 flex flex-wrap items-center gap-3">
              <PillButton href={GITHUB_REPO_URL} variant="secondary" size="md">
                Star on GitHub
              </PillButton>
            </div>
          </div>
        </TapedCard>
      </div>

      <div className="mt-6 grid grid-cols-1 gap-4 md:grid-cols-2">
        {openSourceReasons.map((reason) => (
          <TapedCard key={reason.title} color={reason.color} tapeColor="cream" fill>
            <div className="flex h-full items-start gap-4 p-6">
              <div className="flex h-12 w-14 min-w-14 items-center justify-center rounded-xl border-2 border-ink bg-white text-xs font-semibold">
                {reason.icon}
              </div>
              <div className="flex-1">
                <h3 className="mb-2 text-[22px] font-semibold leading-[1.15]">
                  {reason.title}
                </h3>
                <p className="text-sm leading-[1.55] text-[#222]">
                  {reason.body}
                </p>
              </div>
            </div>
          </TapedCard>
        ))}
      </div>
    </section>
  );
}
