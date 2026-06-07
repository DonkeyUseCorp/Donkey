"use client";

import { BillingPortalButton } from "@/app/_components/landing/BillingPortalButton";
import {
  Headline,
  PillButton,
} from "@/app/_components/landing/LandingPrimitives";
import { Footer } from "@/app/_components/landing/Footer";
import { PricingPlanCard } from "@/app/_components/landing/PricingPlanCard";
import { TopNav } from "@/app/_components/landing/TopNav";
import { pricingPlans } from "@/app/_components/landing/pricingPlans";

export function PricingPage() {
  return (
    <main className="min-h-screen w-full max-w-full overflow-x-hidden bg-background font-system text-ink antialiased">
      <TopNav ctaHref="/sign-in" ctaLabel="Log in" ctaShowArrow={false} />
      <section className="mx-auto w-full max-w-[1400px] px-6 pt-[44px] pb-12 md:px-12 md:pt-[72px] md:pb-16">
        <h1 className="max-w-[700px] text-[52px] leading-[0.9] font-semibold tracking-normal break-words md:max-w-[1304px] md:text-[112px]">
          Pick the plan.
          <br />
          <span className="whitespace-normal min-[1400px]:whitespace-nowrap">
            Let Donkey <span className="italic">carry it.</span>
          </span>
        </h1>
        <p className="mt-8 max-w-[640px] text-[18px] leading-[1.55] text-[#454545] md:text-[20px]">
          Pro is the self-serve path. Enterprise stays personal: tell us what
          your team needs, and we will shape the rollout around it.
        </p>
      </section>

      <section className="mx-auto w-full max-w-[1400px] px-6 pb-20 md:px-12 md:pb-24">
        <div className="grid grid-cols-1 gap-6 md:grid-cols-2">
          {pricingPlans.map((plan) => (
            <PricingPlanCard key={plan.name} plan={plan} />
          ))}
        </div>
      </section>

      <section className="mx-auto w-full max-w-[1400px] px-6 pb-20 md:px-12 md:pb-[120px]">
        <div className="relative">
          <div className="absolute inset-0 translate-x-2 translate-y-2 rounded-3xl bg-coral" />
          <div className="relative grid grid-cols-1 gap-6 rounded-3xl border-2 border-ink bg-ink px-7 py-9 text-white md:grid-cols-[1fr_auto] md:gap-9 md:px-12 md:py-14">
            <div>
              <div className="mb-[18px] text-xs font-semibold tracking-[0.12em] text-white/55 uppercase">
                Already subscribed
              </div>
              <Headline size="lg">Keep billing boring.</Headline>
              <p className="mt-[18px] max-w-[560px] text-[15px] leading-[1.55] text-white/72 md:text-[17px]">
                Manage payment methods, receipts, and subscription details from
                one secure place.
              </p>
            </div>
            <div className="flex flex-wrap items-center gap-3 self-center">
              <BillingPortalButton />
              <PillButton href="/sign-in" variant="primary">
                Log in
              </PillButton>
            </div>
          </div>
        </div>
      </section>
      <Footer />
    </main>
  );
}
