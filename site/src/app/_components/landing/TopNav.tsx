"use client";

import Image from "next/image";
import Link from "next/link";
import { useEffect, useState } from "react";

import { PillButton } from "@/app/_components/landing/LandingPrimitives";
import { authClient } from "@/lib/auth-client";
import { cn } from "@/lib/utils";

const NAV_ICON_SIZE = 59;

type Props = {
  homeHref?: string;
  // Wordmark next to the logo. Donkey Vision is its own B2B product, so that
  // page overrides the default "Donkey" with "Donkey Vision".
  wordmark?: string;
  // Sign-in/up pages show a single toggle to the other mode. Auth otherwise
  // lives on donkeycut.com, so the marketing nav carries no auth entry points.
  authToggle?: { href: string; label: string };
  // Signed-in pill into the product. The Cut landing points it at the Cut
  // projects home, which lives under a different base per host.
  signedInPill?: { href: string; label: string };
  // Signed-out pill into auth. The Cut landing shows a "Log in" pill here (the
  // sign-in screen offers "Create account"), so the nav has a visible way in.
  signedOutPill?: { href: string; label: string };
};

export function TopNav({
  homeHref = "/",
  wordmark = "Donkey",
  authToggle,
  signedInPill = { href: "/app", label: "Dashboard" },
  signedOutPill,
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
    <header className="sticky top-0 z-50 w-full py-3 md:py-4">
      <div
        className={cn(
          "mx-auto flex w-full max-w-[1400px] items-center justify-between rounded-[24px] px-6 py-2 transition-all duration-300 md:px-12 md:py-2.5",
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
              src="/donkey-logo.svg"
              alt=""
              width={NAV_ICON_SIZE}
              height={NAV_ICON_SIZE}
              sizes={`${NAV_ICON_SIZE}px`}
              className="block h-full w-full object-contain"
              unoptimized
            />
          </div>
          <span className="text-2xl font-semibold">{wordmark}</span>
        </Link>
        <div className="flex items-center gap-[10px] md:gap-4">
          {isSignedIn ? (
            <PillButton href={signedInPill.href} variant="secondary" size="sm">
              {signedInPill.label}
            </PillButton>
          ) : signedOutPill ? (
            <PillButton href={signedOutPill.href} variant="secondary" size="sm">
              {signedOutPill.label}
            </PillButton>
          ) : authToggle ? (
            <Link
              href={authToggle.href}
              className="whitespace-nowrap text-sm font-semibold text-ink no-underline"
            >
              {authToggle.label}
            </Link>
          ) : null}
        </div>
      </div>
    </header>
  );
}
