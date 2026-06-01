import { stats } from "@/app/donkeyvision/data";

export function ProofSection() {
  return (
    <section className="mx-auto w-full max-w-[1400px] px-6 pb-20 md:px-12">
      <div className="grid gap-5 md:grid-cols-2">
        {stats.map((stat) => (
          <div className="rounded-lg border-2 border-[#0F0E0D] bg-white p-5" key={stat.label}>
            <div className="text-2xl font-semibold md:text-3xl">{stat.value}</div>
            <div className="mt-2 text-sm leading-6 text-[#555]">{stat.label}</div>
          </div>
        ))}
      </div>
      <div className="mt-5 rounded-lg border-2 border-[#0F0E0D] bg-[#F5D875] p-5 text-sm leading-7 md:text-base">
        Latency ranges are planning estimates for normal screenshot sizes. Very
        large images, queueing, and the optional natural-language grounding step
        can add time. For high-volume usage, we tune the API around your target
        latency.
      </div>
    </section>
  );
}
