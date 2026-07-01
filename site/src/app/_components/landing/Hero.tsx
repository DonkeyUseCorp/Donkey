"use client";

import { ArrowRight } from "lucide-react";

import { PillButton } from "@/app/_components/landing/LandingPrimitives";
import { DONKEY_INSTALL_URL } from "@/app/_components/landing/data";

export function Hero() {
  return (
    <section
      id="top"
      className="mx-auto max-w-[1400px] px-6 pt-8 pb-20 md:px-12 md:pt-16 md:pb-[120px]"
    >
      <h1 className="text-[clamp(45px,9.6vw,134px)] leading-[0.88] font-semibold tracking-[-0.03em]">
        Every Mac
        <br />
        needs a <span className="italic">Donkey.</span>
      </h1>
      <p className="mt-8 max-w-[640px] text-[18px] leading-[1.55] text-[#454545] md:max-w-[900px] md:text-[20px]">
        Donkey does work on your Mac for you. You describe the task, it operates
        your apps to finish it.
      </p>
      <div className="mt-9 flex flex-wrap gap-3">
        <PillButton href={DONKEY_INSTALL_URL} variant="primary" size="lg">
          Download for Mac <ArrowRight size={18} />
        </PillButton>
      </div>
    </section>
  );
}
