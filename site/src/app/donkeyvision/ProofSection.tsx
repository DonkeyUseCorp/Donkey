import { ArrowUpRight } from "lucide-react";

import { stats } from "@/app/donkeyvision/data";

const cardStyles = [
  { bg: "bg-[#EC7868]", rotate: "-rotate-2", tape: "rotate-[-6deg]" },
  { bg: "bg-[#A8D5E8]", rotate: "rotate-2", tape: "rotate-[5deg]" },
];

export function ProofSection() {
  return (
    <section className="mx-auto w-full max-w-[1400px] px-6 pb-20 md:px-12">
      <div className="grid gap-8 sm:grid-cols-2 md:gap-10">
        {stats.map((stat, index) => {
          const style = cardStyles[index % cardStyles.length];

          return (
            <div
              className={`group relative rounded-2xl border-2 border-[#0F0E0D] ${style.bg} ${style.rotate} p-7 shadow-[6px_6px_0_0_#0F0E0D] transition duration-200 hover:-translate-y-1 hover:rotate-0 md:p-8`}
              key={stat.label}
            >
              <span
                aria-hidden="true"
                className={`absolute -top-3 left-1/2 h-6 w-20 -translate-x-1/2 ${style.tape} rounded-sm border-2 border-[#0F0E0D] bg-white/70`}
              />
              <div className="flex items-center gap-1.5 text-xs font-bold uppercase tracking-[0.12em] text-[#0F0E0D]">
                <ArrowUpRight size={14} aria-hidden="true" />
                {stat.eyebrow}
              </div>
              <div className="mt-4 text-5xl font-bold tracking-tight md:text-6xl">
                {stat.value}
              </div>
              <p className="mt-4 max-w-[34ch] text-sm font-medium leading-6 text-[#0F0E0D]/80">
                {stat.label}
              </p>
            </div>
          );
        })}
      </div>
      <p className="mt-8 max-w-3xl text-sm leading-6 text-[#0F0E0D]/60">
        These are measured averages for normal screenshot sizes. Large images
        and queueing add time. For high-volume usage we tune the endpoint to
        your target latency.
      </p>
    </section>
  );
}
