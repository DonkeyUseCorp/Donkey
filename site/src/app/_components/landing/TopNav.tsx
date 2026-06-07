"use client";

import Image from "next/image";
import Link from "next/link";
import { ArrowRight } from "lucide-react";

import { PillButton } from "@/app/_components/landing/LandingPrimitives";
import { DONKEY_INSTALL_URL } from "@/app/_components/landing/data";

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
  return (
    <nav className="mx-auto flex w-full max-w-[1400px] items-center justify-between px-6 py-6 md:px-12 md:py-7">
      <Link
        href={homeHref}
        className="flex items-center gap-0 text-ink no-underline"
      >
        <div className="flex h-[59px] w-[59px] items-center justify-center overflow-hidden rounded-[10px]">
          <Image
            src="/donkey-site-mark.webp"
            alt=""
            width={NAV_ICON_SIZE}
            height={NAV_ICON_SIZE}
            sizes={`${NAV_ICON_SIZE}px`}
            className="block h-full w-full object-cover"
          />
        </div>
        <span className="text-2xl font-semibold">donkey</span>
      </Link>
      <div className="flex items-center gap-[10px] md:gap-4">
        {showAuthLinks ? (
          <>
            <Link
              href="/sign-in"
              className="whitespace-nowrap text-sm font-semibold text-ink no-underline"
            >
              Log in
            </Link>
            <span className="hidden md:inline-flex">
              <PillButton href="/sign-up" variant="secondary" size="sm">
                Sign up
              </PillButton>
            </span>
          </>
        ) : null}
        <PillButton href={ctaHref} variant="dark" size="sm">
          {ctaLabel} <ArrowRight size={14} />
        </PillButton>
      </div>
    </nav>
  );
}
