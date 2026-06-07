"use client";

import Image from "next/image";
import Link from "next/link";
import { ArrowRight } from "lucide-react";

import { PillButton } from "@/app/_components/landing/LandingPrimitives";
import { DONKEY_INSTALL_URL } from "@/app/_components/landing/data";
import { useMediaQuery } from "@/app/_components/landing/useMediaQuery";
import { BLACK } from "@/app/_components/landing/theme";

const NAV_ICON_SIZE = 59;

type Props = {
  ctaHref?: string;
  ctaLabel?: string;
  homeHref?: string;
  showAuthLinks?: boolean;
};

export function TopNav({
  ctaHref = DONKEY_INSTALL_URL,
  ctaLabel = "Download",
  homeHref = "/",
  showAuthLinks = true,
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
      <Link
        href={homeHref}
        style={{
          display: "flex",
          alignItems: "center",
          gap: 0,
          color: BLACK,
          textDecoration: "none",
        }}
      >
        <div
          style={{
            width: NAV_ICON_SIZE,
            height: NAV_ICON_SIZE,
            borderRadius: 10,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            overflow: "hidden",
          }}
        >
          <Image
            src="/donkey-site-mark.webp"
            alt=""
            width={NAV_ICON_SIZE}
            height={NAV_ICON_SIZE}
            sizes={`${NAV_ICON_SIZE}px`}
            style={{
              display: "block",
              width: "100%",
              height: "100%",
              objectFit: "cover",
            }}
          />
        </div>
        <span style={{ fontWeight: 600, fontSize: 24 }}>donkey</span>
      </Link>
      <div style={{ display: "flex", alignItems: "center", gap: isDesktop ? 16 : 10 }}>
        {showAuthLinks ? (
          <>
            <Link
              href="/sign-in"
              style={{
                color: BLACK,
                fontSize: 14,
                fontWeight: 600,
                textDecoration: "none",
                whiteSpace: "nowrap",
              }}
            >
              Sign in
            </Link>
            {isDesktop ? (
              <PillButton href="/sign-up" variant="secondary" size="sm">
                Sign up
              </PillButton>
            ) : null}
          </>
        ) : null}
        <PillButton href={ctaHref} variant="dark" size="sm">
          {ctaLabel} <ArrowRight size={14} />
        </PillButton>
      </div>
    </nav>
  );
}
