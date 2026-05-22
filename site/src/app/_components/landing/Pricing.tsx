"use client";

import { ArrowRight } from "lucide-react";

import {
  Headline,
  PillButton,
} from "@/app/_components/landing/LandingPrimitives";
import { PricingPlanCard } from "@/app/_components/landing/PricingPlanCard";
import { pricingPreviewPlans } from "@/app/_components/landing/pricingPlans";
import { useMediaQuery } from "@/app/_components/landing/useMediaQuery";

export function Pricing() {
  const isDesktop = useMediaQuery("(min-width: 768px)");

  return (
    <section
      id="pricing"
      style={{
        boxSizing: "border-box",
        padding: isDesktop ? "96px 48px" : "80px 24px",
        maxWidth: 1400,
        margin: "0 auto",
        width: "100%",
      }}
    >
      <Headline>
        Plans for the work.{" "}
        <span style={{ fontStyle: "italic" }}>Built for momentum.</span>
      </Headline>
      <p
        style={{
          color: "#454545",
          fontSize: isDesktop ? 18 : 16,
          lineHeight: 1.55,
          margin: "24px 0 0",
          maxWidth: 620,
        }}
      >
        Start with Pro when you are ready for self-serve billing, or talk to us
        about rolling Donkey out across a team.
      </p>
      <div
        style={{
          marginTop: 48,
          display: "grid",
          gridTemplateColumns: isDesktop ? "1fr 1fr" : "1fr",
          gap: 24,
        }}
      >
        {pricingPreviewPlans.map((plan) => (
          <PricingPlanCard key={plan.name} plan={plan} />
        ))}
      </div>
      <div style={{ marginTop: 36 }}>
        <PillButton href="/pricing" variant="secondary" size="lg">
          Open pricing <ArrowRight size={18} />
        </PillButton>
      </div>
    </section>
  );
}
