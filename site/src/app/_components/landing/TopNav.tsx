"use client";

import { ArrowRight, Smile } from "lucide-react";

import { PillButton } from "@/app/_components/landing/LandingPrimitives";
import { useMediaQuery } from "@/app/_components/landing/useMediaQuery";
import { BLACK } from "@/app/_components/landing/theme";

type Props = {
  ctaHref?: string;
  ctaLabel?: string;
  homeHref?: string;
};

export function TopNav({
  ctaHref = "#download",
  ctaLabel = "Download",
  homeHref = "/",
}: Props) {
  const isDesktop = useMediaQuery("(min-width: 768px)");

  return (
    <nav
      style={{
        display: "flex",
        alignItems: "center",
        boxSizing: "border-box",
        justifyContent: "space-between",
        padding: isDesktop ? "28px 48px" : "24px 24px",
        maxWidth: 1400,
        margin: "0 auto",
        width: "100%",
      }}
    >
      <a
        href={homeHref}
        style={{
          display: "flex",
          alignItems: "center",
          gap: 8,
          color: BLACK,
          textDecoration: "none",
        }}
      >
        <div
          style={{
            width: 36,
            height: 36,
            borderRadius: 8,
            background: BLACK,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
          }}
        >
          <Smile color="#fff" size={20} />
        </div>
        <span style={{ fontWeight: 900, fontSize: 24 }}>donkey</span>
      </a>
      <PillButton href={ctaHref} variant="dark" size="sm">
        {ctaLabel} <ArrowRight size={14} />
      </PillButton>
    </nav>
  );
}
