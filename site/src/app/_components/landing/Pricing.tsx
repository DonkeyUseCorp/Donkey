"use client";

import { Headline } from "@/app/_components/landing/LandingPrimitives";
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
      <div
        style={{
          marginTop: 48,
          display: "grid",
          gridTemplateColumns: isDesktop ? "1fr 1fr" : "1fr",
          alignItems: "stretch",
          gap: 24,
        }}
      >
        {pricingPreviewPlans.map((plan) => (
          <PricingPlanCard key={plan.name} plan={plan} />
        ))}
      </div>
    </section>
  );
}
