import { Braces, Server } from "lucide-react";

import {
  elementResponseExample,
  features,
  groundingRequestExample,
  groundingResponseExample,
  requestExample,
} from "@/app/donkeyvision/data";
import type { Feature } from "@/app/donkeyvision/types";

type FeatureLineProps = {
  feature: Feature;
};

type ExampleBlockProps = {
  code: string;
  title: string;
};

export function ApiSection() {
  return (
    <section
      className="border-y-2 border-[#0F0E0D] bg-[#FAF6EC] px-6 py-20 md:px-12"
      id="api"
    >
      <div className="mx-auto max-w-[1400px]">
        <div className="grid gap-10 lg:grid-cols-[0.85fr_1.15fr]">
          <div className="min-w-0">
            <div className="mb-5 inline-flex w-fit items-center gap-2 rounded-md bg-[#0F0E0D] px-3 py-2 text-xs font-semibold uppercase tracking-[0.12em] text-white">
              <Server size={15} aria-hidden="true" />
              POST /api/inference/vision
            </div>
            <h2 className="max-w-2xl text-4xl font-semibold leading-none md:text-6xl">
              One endpoint, two jobs.
            </h2>
            <p className="mt-6 max-w-2xl text-lg leading-8 text-[#454545]">
              Donkey Vision first runs OmniParser to produce element IDs, labels,
              boxes, center points, and interactivity. If you include an instruction,
              the LLM only receives that compact element catalog and picks the best
              target. Coordinates come from the parser output, not the LLM.
            </p>
            <div className="mt-8 grid gap-4">
              {features.map((feature) => (
                <FeatureLine feature={feature} key={feature.title} />
              ))}
            </div>
          </div>
          <div className="grid min-w-0 gap-5">
            <ExampleBlock code={requestExample} title="Return all elements" />
            <ExampleBlock code={elementResponseExample} title="Element response" />
            <ExampleBlock code={groundingRequestExample} title="Ask about a screenshot" />
            <ExampleBlock code={groundingResponseExample} title="Grounded target" />
          </div>
        </div>
      </div>
    </section>
  );
}

function FeatureLine({ feature }: FeatureLineProps) {
  const Icon = feature.icon;

  return (
    <div className="flex gap-4 rounded-lg border-2 border-[#0F0E0D] bg-white p-4">
      <div className="flex h-11 w-11 shrink-0 items-center justify-center rounded-md border-2 border-[#0F0E0D] bg-[#A8D5E8]">
        <Icon size={20} aria-hidden="true" />
      </div>
      <div>
        <h3 className="text-lg font-semibold">{feature.title}</h3>
        <p className="mt-1 text-sm leading-6 text-[#555]">{feature.description}</p>
      </div>
    </div>
  );
}

function ExampleBlock({ code, title }: ExampleBlockProps) {
  return (
    <div className="min-w-0 max-w-full overflow-hidden rounded-lg border-2 border-[#0F0E0D] bg-[#0F0E0D]">
      <div className="flex items-center justify-between border-b-2 border-white/15 px-4 py-3 text-sm font-semibold text-white">
        <span>{title}</span>
        <Braces size={16} aria-hidden="true" />
      </div>
      <pre className="max-w-full overflow-x-auto p-4 text-xs leading-6 text-white md:text-sm">
        <code>{code}</code>
      </pre>
    </div>
  );
}
