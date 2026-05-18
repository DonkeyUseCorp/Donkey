"use client";

import { ArrowRight } from "lucide-react";

import {
  Headline,
  PillButton,
  SectionLabel,
  TapedCard,
} from "@/app/_components/landing/LandingPrimitives";
import { useMediaQuery } from "@/app/_components/landing/useMediaQuery";

export function Pricing() {
  const isDesktop = useMediaQuery("(min-width: 768px)");

  return (
    <section
      id="pricing"
      style={{
        padding: isDesktop ? "96px 48px" : "80px 24px",
        maxWidth: 1400,
        margin: "0 auto",
      }}
    >
      <SectionLabel number={7}>Pricing</SectionLabel>
      <Headline>
        Free for now. <span style={{ fontStyle: "italic" }}>Forever curious.</span>
      </Headline>
      <div
        style={{
          marginTop: 48,
          display: "grid",
          gridTemplateColumns: isDesktop ? "1fr 1fr" : "1fr",
          gap: 24,
        }}
      >
        <TapedCard color="cream" tapeColor="coral">
          <div style={{ padding: isDesktop ? 36 : 28 }}>
            <div style={{ fontWeight: 900, fontSize: 22, marginBottom: 8 }}>
              Free
            </div>
            <div style={{ display: "flex", alignItems: "baseline", gap: 8 }}>
              <span style={{ fontWeight: 900, fontSize: isDesktop ? 56 : 44 }}>
                $0
              </span>
            </div>
            <div
              style={{
                fontSize: 13,
                fontWeight: 700,
                color: "#444",
                marginBottom: 24,
              }}
            >
              during beta
            </div>
            <p
              style={{
                fontSize: 15,
                lineHeight: 1.55,
                color: "#222",
                margin: "0 0 28px",
              }}
            >
              Everything Donkey can do, no caps, no credit card. We want you
              using it.
            </p>
            <PillButton href="#download" variant="dark" size="md">
              Get Donkey <ArrowRight size={14} />
            </PillButton>
          </div>
        </TapedCard>

        <TapedCard color="coral" tapeColor="yellow" tapePosition="right">
          <div style={{ padding: isDesktop ? 36 : 28 }}>
            <div style={{ fontWeight: 900, fontSize: 22, marginBottom: 8 }}>
              Enterprise
            </div>
            <div style={{ display: "flex", alignItems: "baseline", gap: 8 }}>
              <span style={{ fontWeight: 900, fontSize: isDesktop ? 56 : 44 }}>
                Let&apos;s talk
              </span>
            </div>
            <div
              style={{
                fontSize: 13,
                fontWeight: 700,
                color: "#222",
                marginBottom: 24,
              }}
            >
              built around your team
            </div>
            <p
              style={{
                fontSize: 15,
                lineHeight: 1.55,
                color: "#1a1a1a",
                margin: "0 0 28px",
              }}
            >
              Running Donkey across an org? Reach out and we will figure out
              what makes sense.
            </p>
            <PillButton href="mailto:david@donkeyuse.com" variant="dark" size="md">
              Contact us <ArrowRight size={14} />
            </PillButton>
          </div>
        </TapedCard>
      </div>
    </section>
  );
}
