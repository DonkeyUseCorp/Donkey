import { ArrowDown, Braces } from "lucide-react";

import {
  elementResponseExample,
  features,
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

type ExamplePairProps = {
  badge: string;
  caption: string;
  request: string;
  requestTitle: string;
  response: string;
  responseTitle: string;
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
            <h2 className="max-w-2xl text-4xl font-semibold leading-none md:text-6xl">
              One endpoint, one job.
            </h2>
            <p className="mt-6 max-w-2xl text-lg leading-8 text-[#454545]">
              Send a screenshot and every request returns the same compact
              element catalog: IDs, labels, kinds, boxes, center points, and
              interactivity flags. Coordinates come straight from the parser, in
              the image space you sent.
            </p>
            <div className="mt-8 grid gap-4">
              {features.map((feature) => (
                <FeatureLine feature={feature} key={feature.title} />
              ))}
            </div>
          </div>
          <div className="grid min-w-0 gap-8">
            <ExamplePair
              badge="Parse"
              caption="Detect every interactable element."
              request={requestExample}
              requestTitle="Request"
              response={elementResponseExample}
              responseTitle="Response"
            />
          </div>
        </div>
      </div>
    </section>
  );
}

function ExamplePair({
  badge,
  caption,
  request,
  requestTitle,
  response,
  responseTitle,
}: ExamplePairProps) {
  return (
    <div className="min-w-0">
      <div className="mb-3 flex items-center gap-3">
        <span className="inline-flex items-center rounded-full border-2 border-[#0F0E0D] bg-[#F5D875] px-3 py-1 text-xs font-semibold uppercase tracking-[0.08em]">
          {badge}
        </span>
        <span className="text-sm font-semibold text-[#0F0E0D]">{caption}</span>
      </div>
      <div className="grid gap-2">
        <ExampleBlock code={request} title={requestTitle} />
        <div className="flex justify-center">
          <ArrowDown size={18} className="text-[#0F0E0D]" aria-hidden="true" />
        </div>
        <ExampleBlock code={response} title={responseTitle} />
      </div>
    </div>
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
