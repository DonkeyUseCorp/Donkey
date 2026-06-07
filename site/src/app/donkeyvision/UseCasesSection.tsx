import { InlineMarkup } from "@/app/donkeyvision/codeHighlight";
import { useCases } from "@/app/donkeyvision/data";
import type { Feature } from "@/app/donkeyvision/types";

type Props = {
  feature: Feature;
};

export function UseCasesSection() {
  return (
    <section className="mx-auto w-full max-w-[1400px] px-6 py-20 md:px-12">
      <div className="mb-10">
        <h2 className="text-4xl font-semibold leading-none md:whitespace-nowrap md:text-6xl">
          Use screenshots when there is no API.
        </h2>
        <p className="mt-5 max-w-2xl text-lg leading-8 text-[#454545]">
          Send a screenshot from any application. Donkey Vision returns detected
          UI elements, labels, bounding boxes, center points, and optional
          prompt-matched click targets.
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
      <p className="mt-3 text-sm leading-6 text-[#555]">
        <InlineMarkup text={feature.description} />
      </p>
    </div>
  );
}
