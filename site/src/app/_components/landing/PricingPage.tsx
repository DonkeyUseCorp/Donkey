"use client";

import { ArrowRight } from "lucide-react";

import { BillingPortalButton } from "@/app/_components/landing/BillingPortalButton";
import {
  Headline,
  PillButton,
} from "@/app/_components/landing/LandingPrimitives";
import { Footer } from "@/app/_components/landing/Footer";
import { PricingPlanCard } from "@/app/_components/landing/PricingPlanCard";
import { TopNav } from "@/app/_components/landing/TopNav";
import { pricingPlans } from "@/app/_components/landing/pricingPlans";
import { BG, BLACK } from "@/app/_components/landing/theme";
import { useMediaQuery } from "@/app/_components/landing/useMediaQuery";

export function PricingPage() {
  const isDesktop = useMediaQuery("(min-width: 768px)");
  const isWideDesktop = useMediaQuery("(min-width: 1400px)");

  return (
    <main
      style={{
        WebkitFontSmoothing: "antialiased",
        background: BG,
        color: BLACK,
        boxSizing: "border-box",
        fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
        maxWidth: "100%",
        minHeight: "100vh",
        overflowX: "hidden",
        width: "100%",
      }}
    >
      <TopNav ctaHref="/sign-in" ctaLabel="Sign in" />
      <section
        style={{
          boxSizing: "border-box",
          margin: "0 auto",
          maxWidth: 1400,
          padding: isDesktop ? "72px 48px 64px" : "44px 24px 48px",
          width: "100%",
        }}
      >
        <h1
          style={{
            fontSize: isDesktop ? 112 : 52,
            fontWeight: 900,
            letterSpacing: 0,
            lineHeight: 0.9,
            margin: 0,
            maxWidth: isDesktop ? 1304 : 700,
            overflowWrap: "break-word",
          }}
        >
          Pick the plan.
          <br />
          <span style={{ whiteSpace: isWideDesktop ? "nowrap" : "normal" }}>
            Let Donkey <span style={{ fontStyle: "italic" }}>carry it.</span>
          </span>
        </h1>
        <p
          style={{
            color: "#454545",
            fontSize: isDesktop ? 20 : 18,
            lineHeight: 1.55,
            marginTop: 32,
            maxWidth: 640,
          }}
        >
          Pro is the self-serve path through Stripe. Enterprise stays personal:
          tell us what your team needs, and we will shape the rollout around it.
        </p>
      </section>

      <section
        style={{
          boxSizing: "border-box",
          margin: "0 auto",
          maxWidth: 1400,
          padding: isDesktop ? "0 48px 96px" : "0 24px 80px",
          width: "100%",
        }}
      >
        <div
          style={{
            display: "grid",
            gap: 24,
            gridTemplateColumns: isDesktop ? "1fr 1fr" : "1fr",
          }}
        >
          {pricingPlans.map((plan) => (
            <PricingPlanCard key={plan.name} plan={plan} />
          ))}
        </div>
      </section>

      <section
        style={{
          boxSizing: "border-box",
          margin: "0 auto",
          maxWidth: 1400,
          padding: isDesktop ? "0 48px 120px" : "0 24px 80px",
          width: "100%",
        }}
      >
        <div style={{ position: "relative" }}>
          <div
            style={{
              background: "#EC7868",
              borderRadius: 24,
              inset: 0,
              position: "absolute",
              transform: "translate(8px, 8px)",
            }}
          />
          <div
            style={{
              background: BLACK,
              border: `2px solid ${BLACK}`,
              borderRadius: 24,
              color: "#fff",
              display: "grid",
              gap: isDesktop ? 36 : 24,
              gridTemplateColumns: isDesktop ? "1fr auto" : "1fr",
              padding: isDesktop ? "56px 48px" : "36px 28px",
              position: "relative",
            }}
          >
            <div>
              <div
                style={{
                  color: "rgba(255,255,255,0.55)",
                  fontSize: 12,
                  fontWeight: 800,
                  letterSpacing: "0.12em",
                  marginBottom: 18,
                  textTransform: "uppercase",
                }}
              >
                Already subscribed
              </div>
              <Headline size="lg">Keep billing boring.</Headline>
              <p
                style={{
                  color: "rgba(255,255,255,0.72)",
                  fontSize: isDesktop ? 17 : 15,
                  lineHeight: 1.55,
                  margin: "18px 0 0",
                  maxWidth: 560,
                }}
              >
                Manage payment methods, receipts, and subscription details from
                one Stripe-hosted place.
              </p>
            </div>
            <div
              style={{
                alignSelf: "center",
                display: "flex",
                flexWrap: "wrap",
                gap: 12,
              }}
            >
              <BillingPortalButton />
              <PillButton href="/sign-in" variant="primary">
                Sign in <ArrowRight size={14} />
              </PillButton>
            </div>
          </div>
        </div>
      </section>
      <Footer />
    </main>
  );
}
