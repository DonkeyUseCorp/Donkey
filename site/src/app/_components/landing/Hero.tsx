"use client";

import { ArrowRight } from "lucide-react";

import { PillButton, SectionLabel } from "@/app/_components/landing/LandingPrimitives";
import { useMediaQuery } from "@/app/_components/landing/useMediaQuery";

export function Hero() {
  const isDesktop = useMediaQuery("(min-width: 768px)");

  return (
    <section
      id="top"
      style={{
        padding: isDesktop ? "64px 48px 120px" : "32px 24px 80px",
        maxWidth: 1400,
        margin: "0 auto",
      }}
    >
      <SectionLabel number={1}>Your Mac, on autopilot</SectionLabel>
      <h1
        style={{
          fontWeight: 900,
          letterSpacing: "-0.03em",
          lineHeight: 0.88,
          fontSize: "clamp(56px, 12vw, 168px)",
          margin: 0,
        }}
      >
        Get work done
        <br />
        while <span style={{ fontStyle: "italic" }}>you sleep.</span>
      </h1>
      <p
        style={{
          marginTop: 32,
          fontSize: isDesktop ? 20 : 18,
          lineHeight: 1.55,
          maxWidth: 560,
          color: "#454545",
        }}
      >
        Donkey gets work done on your Mac. Tell it what to do: research,
        drafting, scheduling, scraping, and it runs the rest of your machine for
        you.
      </p>
      <div style={{ marginTop: 36, display: "flex", flexWrap: "wrap", gap: 12 }}>
        <PillButton href="#download" variant="primary" size="lg">
          Download for Mac <ArrowRight size={18} />
        </PillButton>
      </div>
      <div
        style={{
          marginTop: 28,
          display: "flex",
          alignItems: "center",
          gap: 14,
          fontSize: 13,
          color: "#666",
          flexWrap: "wrap",
        }}
      >
        <span>Free during beta</span>
      </div>
    </section>
  );
}
