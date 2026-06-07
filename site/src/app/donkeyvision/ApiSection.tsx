import { ApiReference } from "@/app/donkeyvision/ApiReference";
import { InlineMarkup } from "@/app/donkeyvision/codeHighlight";
import { features } from "@/app/donkeyvision/data";
import type { Feature } from "@/app/donkeyvision/types";

type FeatureLineProps = {
  feature: Feature;
};

export function ApiSection() {
  return (
    <section
      className="border-b-2 border-[#0F0E0D] bg-[#FAF6EC] py-20"
      id="api"
    >
      <div className="mx-auto max-w-[1400px] px-6 md:px-12">
        <div className="max-w-3xl">
          <h2 className="text-4xl font-semibold leading-none md:text-6xl">
            How the API works
          </h2>
          <p className="mt-6 text-lg leading-8 text-[#454545]">
            Send a screenshot to <Code>/api/vision</Code>. The response
            includes detected UI elements with IDs, labels, types, bounding
            boxes, center points, and confidence scores.
          </p>
          <p className="mt-4 text-lg leading-8 text-[#454545]">
            Add an optional text instruction, such as{" "}
            <Code>click the play button</Code>, to return the matching click
            target. Model selection supports ChatGPT, Claude, Gemini, or a custom
            model.
          </p>
        </div>

        <div className="mt-10 grid gap-x-10 gap-y-8 sm:grid-cols-2 lg:grid-cols-3">
          {features.map((feature) => (
            <FeatureLine feature={feature} key={feature.title} />
          ))}
        </div>

        <ApiReference />
      </div>
    </section>
  );
}

function FeatureLine({ feature }: FeatureLineProps) {
  const Icon = feature.icon;

  return (
    <div className="flex gap-3">
      <Icon
        size={20}
        aria-hidden="true"
        className="mt-0.5 shrink-0 text-[#0F0E0D]"
      />
      <div>
        <h3 className="text-base font-semibold">{feature.title}</h3>
        <p className="mt-1 text-sm leading-6 text-[#555]">
          <InlineMarkup text={feature.description} />
        </p>
      </div>
    </div>
  );
}

function Code({ children }: { children: string }) {
  return (
    <code className="rounded bg-[#0F0E0D]/8 px-1.5 py-0.5 font-mono text-[0.85em] text-[#0F0E0D]">
      {children}
    </code>
  );
}
