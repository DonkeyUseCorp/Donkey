import { useCases } from "@/app/donkeyvision/data";
import type { Feature } from "@/app/donkeyvision/types";

type Props = {
  feature: Feature;
};

export function UseCasesSection() {
  return (
    <section className="mx-auto w-full max-w-[1400px] px-6 py-20 md:px-12">
      <div className="mb-10 flex flex-col justify-between gap-5 md:flex-row md:items-end">
        <div>
          <div className="mb-5 inline-flex w-fit rounded-md bg-[#0F0E0D] px-3 py-2 text-xs font-semibold uppercase tracking-[0.12em] text-white">
            Use cases
          </div>
          <h2 className="max-w-3xl text-4xl font-semibold leading-none md:text-6xl">
            Screen understanding for software that does not expose an API.
          </h2>
        </div>
        <p className="max-w-lg text-lg leading-8 text-[#454545]">
          Upload a screenshot from any application and get a structured UI map.
          Add a natural-language instruction when your product needs a target
          instead of a full element list.
        </p>
      </div>
      <div className="grid gap-5 md:grid-cols-2 lg:grid-cols-4">
        {useCases.map((feature) => (
          <UseCaseCard feature={feature} key={feature.title} />
        ))}
      </div>
    </section>
  );
}

function UseCaseCard({ feature }: Props) {
  const Icon = feature.icon;

  return (
    <div className="rounded-lg border-2 border-[#0F0E0D] bg-white p-5">
      <div className="mb-5 flex h-12 w-12 items-center justify-center rounded-md border-2 border-[#0F0E0D] bg-[#F2B5C4]">
        <Icon size={22} aria-hidden="true" />
      </div>
      <h3 className="text-xl font-semibold leading-7">{feature.title}</h3>
      <p className="mt-3 text-sm leading-6 text-[#555]">{feature.description}</p>
    </div>
  );
}
