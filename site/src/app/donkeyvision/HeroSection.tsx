import { Braces } from "lucide-react";

import { VisionPreview } from "@/app/donkeyvision/VisionPreview";

export function HeroSection() {
  return (
    <section className="mx-auto grid w-full max-w-[1400px] gap-10 px-6 pb-16 pt-10 md:grid-cols-[minmax(0,1.02fr)_minmax(420px,0.98fr)] md:px-12 md:pb-24 md:pt-16">
      <div className="flex min-w-0 flex-col justify-center">
        <h1 className="max-w-4xl break-words text-[46px] font-semibold leading-[0.92] sm:text-[54px] md:text-[76px] md:leading-[0.9] lg:text-[92px]">
          An API for <span className="italic">clickable UI</span> from
          screenshots.
        </h1>
        <p className="mt-7 max-w-2xl break-words text-lg leading-8 text-[#454545] md:text-xl">
          Donkey Vision finds every interactable element in a screenshot —
          buttons, icons, inputs, rows — and returns each one&rsquo;s box, center
          point, and label. It reads pixels, so it works on software that exposes
          no API at all.
        </p>
        <div className="mt-9 flex max-w-full flex-wrap gap-3">
          <a
            className="inline-flex min-h-14 items-center justify-center gap-2 rounded-full border-2 border-[#0F0E0D] bg-white px-7 text-base font-semibold text-[#0F0E0D] transition hover:-translate-y-0.5"
            href="#api"
          >
            See the API <Braces size={18} aria-hidden="true" />
          </a>
        </div>
        <p className="mt-7 text-sm text-[#666]">
          The same screen-understanding layer Donkey uses to read and drive apps
          on your Mac.
        </p>
      </div>
      <VisionPreview />
    </section>
  );
}
