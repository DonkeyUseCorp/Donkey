import { ApiReference } from "@/app/donkeyvision/ApiReference";
import { features } from "@/app/donkeyvision/data";
import type { Feature } from "@/app/donkeyvision/types";

type FeatureLineProps = {
  feature: Feature;
};

export function ApiSection() {
  return (
    <section
      className="border-b-2 border-[#0F0E0D] bg-[#FAF6EC] px-6 py-20 md:px-12"
      id="api"
    >
      <div className="mx-auto max-w-[1400px]">
        <div className="max-w-3xl">
          <h2 className="text-4xl font-semibold leading-none md:text-6xl">
            Here&rsquo;s how the API works.
          </h2>
          <p className="mt-6 text-lg leading-8 text-[#454545]">
            Send a screenshot to <Code>/parse</Code>. The response is a list of
            detected UI elements with IDs, labels, types, boxes, center points,
            and confidence scores.
          </p>
          <p className="mt-4 text-lg leading-8 text-[#454545]">
            You can also send a text prompt, like{" "}
            <Code>click the play button</Code>, and get back the exact region to
            click. Use your choice of LLM: ChatGPT, Claude, Gemini, or a custom
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
          {feature.description}
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
