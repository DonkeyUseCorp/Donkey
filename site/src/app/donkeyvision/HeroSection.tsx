import { ArrowRight, Braces, Gauge } from "lucide-react";

import { VisionPreview } from "@/app/donkeyvision/VisionPreview";

export function HeroSection() {
  return (
    <section className="mx-auto grid w-full max-w-[1400px] gap-10 px-6 pb-16 pt-10 md:grid-cols-[minmax(0,1.02fr)_minmax(420px,0.98fr)] md:px-12 md:pb-24 md:pt-16">
      <div className="flex min-w-0 flex-col justify-center">
        <div className="mb-6 inline-flex w-fit items-center gap-2 rounded-md border-2 border-[#0F0E0D] bg-white px-3 py-2 text-xs font-semibold uppercase tracking-[0.12em]">
          <Gauge size={15} aria-hidden="true" />
          Low-latency UI vision API
        </div>
        <h1 className="max-w-4xl break-words text-[52px] font-semibold leading-[0.92] sm:text-[56px] md:text-[88px] md:leading-[0.9] lg:text-[112px]">
          Donkey Vision
        </h1>
        <p className="mt-7 max-w-2xl break-words text-lg leading-8 text-[#454545] md:text-xl">
          Detect every interactable UI element in a screenshot, then optionally ask
          natural-language questions like find the play button or find the next
          button. It works across software because it reads the screen, not a
          private app integration.
        </p>
        <div className="mt-9 flex max-w-full flex-wrap gap-3">
          <a
            className="inline-flex min-h-14 items-center justify-center gap-2 rounded-full border-2 border-[#0F0E0D] bg-[#EC7868] px-7 text-base font-semibold text-[#0F0E0D] transition hover:-translate-y-0.5"
            href="#contact"
          >
            Contact us <ArrowRight size={18} aria-hidden="true" />
          </a>
          <a
            className="inline-flex min-h-14 items-center justify-center gap-2 rounded-full border-2 border-[#0F0E0D] bg-white px-7 text-base font-semibold text-[#0F0E0D] transition hover:-translate-y-0.5"
            href="#api"
          >
            See API shape <Braces size={18} aria-hidden="true" />
          </a>
        </div>
      </div>
      <VisionPreview />
    </section>
  );
}
