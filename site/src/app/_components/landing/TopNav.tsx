"use client";

import Image from "next/image";
import Link from "next/link";
import { useEffect, useState } from "react";
import { ArrowRight } from "lucide-react";

import { PillButton } from "@/app/_components/landing/LandingPrimitives";
import { DONKEY_INSTALL_URL } from "@/app/_components/landing/data";
import { authClient } from "@/lib/auth-client";
import { cn } from "@/lib/utils";

const NAV_ICON_SIZE = 59;

type Props = {
  ctaHref?: string;
  ctaLabel?: string;
  homeHref?: string;
  showAuthLinks?: boolean;
  // The arrow accent is reserved for the download CTA; non-download CTAs
  // (Log in, Get started, auth toggles) pass false.
  ctaShowArrow?: boolean;
};

export function TopNav({
  ctaHref = DONKEY_INSTALL_URL,
  ctaLabel = "Download",
  homeHref = "/",
  showAuthLinks = true,
  ctaShowArrow = true,
}: Props) {
  // Signed-in visitors don't need the auth links or the download CTA; the whole
  // right cluster collapses to a single white button into the product. During the
  // initial (pending) client render `session` is null, which matches the static
  // server HTML, so the signed-out cluster shows first and swaps in on resolve.
  const { data: session } = authClient.useSession();
  const isSignedIn = Boolean(session);

  // The header is sticky and transparent over the hero; once the page scrolls a
  // little it fades in a translucent backdrop and a hairline divider so the nav
  // stays legible over the content scrolling underneath.
  const [scrolled, setScrolled] = useState(false);
  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 10);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  return (
    <header className="sticky top-0 z-50 w-full px-4 py-3 md:px-8 md:py-4">
      <div
        className={cn(
          "mx-auto flex w-full max-w-[1400px] items-center justify-between rounded-[24px] px-5 py-2 transition-all duration-300 md:px-7 md:py-2.5",
          scrolled
            ? "border border-ink/10 bg-cream/95 shadow-[0_18px_50px_rgba(15,14,13,0.10)] backdrop-blur-md"
            : "border border-transparent bg-transparent shadow-none",
        )}
      >
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
          {isSignedIn ? (
            <PillButton href="/app" variant="secondary" size="sm">
              Dashboard
            </PillButton>
          ) : (
            <>
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
                {ctaLabel}
                {ctaShowArrow ? <ArrowRight size={14} /> : null}
              </PillButton>
            </>
          )}
        </div>
      </div>
    </header>
  );
}
