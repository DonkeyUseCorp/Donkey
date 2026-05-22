"use client";

import { ArrowRight } from "lucide-react";

import { PillButton } from "@/app/_components/landing/LandingPrimitives";
import { GITHUB_REPO_URL } from "@/app/_components/landing/data";
import { useMediaQuery } from "@/app/_components/landing/useMediaQuery";
import { BLACK, CORAL } from "@/app/_components/landing/theme";

export function FinalCTA() {
  const isDesktop = useMediaQuery("(min-width: 768px)");

  return (
    <section
      id="download"
      style={{
        boxSizing: "border-box",
        padding: isDesktop ? "64px 48px 120px" : "48px 24px 80px",
        maxWidth: 1400,
        margin: "0 auto",
        width: "100%",
      }}
    >
      <div style={{ position: "relative" }}>
        <div
          style={{
            position: "absolute",
            inset: 0,
            transform: "translate(8px, 8px)",
            borderRadius: 24,
            background: CORAL,
          }}
        />
        <div
          style={{
            position: "relative",
            borderRadius: 24,
            border: `2px solid ${BLACK}`,
            background: BLACK,
            color: "#fff",
            padding: isDesktop ? "80px 48px" : "40px 24px",
            textAlign: "center",
          }}
        >
          <div
            style={{
              position: "absolute",
              top: -10,
              left: "50%",
              transform: "translateX(-50%) rotate(-2deg)",
              width: 80,
              height: 18,
              borderRadius: 3,
              border: `2px solid ${BLACK}`,
              background: CORAL,
            }}
          />
          <div
            style={{
              fontSize: 12,
              fontWeight: 800,
              letterSpacing: "0.12em",
              textTransform: "uppercase",
              color: "rgba(255,255,255,0.6)",
              marginBottom: 20,
            }}
          >
            Start with Donkey
          </div>
          <h2
            style={{
              fontWeight: 900,
              fontSize: "clamp(40px, 7vw, 80px)",
              lineHeight: 0.95,
              margin: "0 0 16px",
            }}
          >
            Let Donkey
            <br />
            carry the load.
          </h2>
          <p
            style={{
              color: "rgba(255,255,255,0.7)",
              fontSize: isDesktop ? 18 : 16,
              marginBottom: 32,
              maxWidth: 480,
              marginLeft: "auto",
              marginRight: "auto",
            }}
          >
            Free during beta. Installs in 90 seconds.
          </p>
          <div
            style={{
              display: "flex",
              flexWrap: "wrap",
              gap: 12,
              justifyContent: "center",
            }}
          >
            <PillButton href={GITHUB_REPO_URL} variant="primary" size="lg">
              Download for Mac <ArrowRight size={18} />
            </PillButton>
            <PillButton href="/pricing" variant="secondary" size="lg">
              See pricing
            </PillButton>
          </div>
        </div>
      </div>
    </section>
  );
}
