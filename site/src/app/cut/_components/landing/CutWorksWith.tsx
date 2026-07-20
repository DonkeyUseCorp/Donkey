"use client";

import { Headline, TapedCard } from "@/app/_components/landing/LandingPrimitives";

// The assistant rides the Claude and Codex logins already on the user's Mac,
// so a subscription is all it takes — this section says exactly that.
const PROVIDERS = [
  { name: "Claude", logo: "/cut/landing/claude-logo.svg", color: "blue" as const },
  { name: "Codex", logo: "/cut/landing/openai-logo.svg", color: "yellow" as const },
];

export function CutWorksWith() {
  return (
    <section className="mx-auto max-w-[1400px] px-6 py-20 md:px-12 md:py-24">
      <Headline size="lg">
        Works with <span className="italic">Claude and Codex.</span>
      </Headline>
      <p className="mt-6 max-w-[720px] text-[17px] leading-[1.55] text-[#454545]">
        The assistant uses the Claude and Codex apps already signed in on your
        Mac. If you have a subscription, you're done — no setup, no API keys.
      </p>
      <div className="mt-12 grid grid-cols-1 gap-6 md:grid-cols-2">
        {PROVIDERS.map((provider) => (
          <TapedCard key={provider.name} color={provider.color} tapeColor="cream" fill>
            <div className="flex h-full items-center justify-center gap-4 px-6 py-14">
              <img src={provider.logo} alt="" className="size-11 md:size-12" />
              <span className="text-[clamp(28px,3.5vw,44px)] font-semibold tracking-tight">
                {provider.name}
              </span>
            </div>
          </TapedCard>
        ))}
      </div>
    </section>
  );
}
