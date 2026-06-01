import { Check } from "lucide-react";

import { surfaces } from "@/app/donkeyvision/data";

export function MediaSection() {
  return (
    <section className="border-y-2 border-[#0F0E0D] bg-white px-6 py-20 md:px-12">
      <div className="mx-auto grid max-w-[1400px] gap-10 lg:grid-cols-[0.85fr_1.15fr]">
        <div>
          <h2 className="max-w-2xl text-4xl font-semibold leading-none md:text-6xl">
            If you can screenshot it, Donkey Vision can read it.
          </h2>
          <p className="mt-6 max-w-2xl text-lg leading-8 text-[#454545]">
            Detection works on pixels, not a private integration or the DOM. The
            same request handles a native Mac window, a browser tab, or a remote
            desktop — no per-app setup and no brittle selectors.
          </p>
        </div>
        <div className="grid gap-4 sm:grid-cols-2">
          {surfaces.map((surface) => (
            <div
              className="flex items-center gap-3 rounded-lg border-2 border-[#0F0E0D] bg-[#FAF6EC] p-4"
              key={surface}
            >
              <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-md border-2 border-[#0F0E0D] bg-[#B7E4C7]">
                <Check size={18} aria-hidden="true" />
              </span>
              <span className="text-base font-semibold leading-6">{surface}</span>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}
