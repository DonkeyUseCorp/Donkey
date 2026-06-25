"use client";

import Image from "next/image";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";
import { ArrowRight } from "lucide-react";

import { PillButton } from "@/app/_components/landing/LandingPrimitives";
import { DONKEY_INSTALL_URL } from "@/app/_components/landing/data";
import { authClient } from "@/lib/auth-client";
import { cn } from "@/lib/utils";

const NAV_ICON_SIZE = 59;

type Props = {
  homeHref?: string;
  // Wordmark next to the logo. Donkey Vision is its own B2B product, so that
  // page overrides the default "donkey" with "donkey vision".
  wordmark?: string;
  // Product nav links (e.g. Use cases). Auth screens keep a minimal header and
  // opt out.
  showNav?: boolean;
  // Log in + Sign up cluster. Hidden when an authToggle is supplied.
  showAuthLinks?: boolean;
  // The Download pill belongs to the main landing page only.
  showDownload?: boolean;
  // Sign-in/up pages swap the auth links for a single toggle to the other mode.
  authToggle?: { href: string; label: string };
};

export function TopNav({
  homeHref = "/",
  wordmark = "donkey",
  showNav = true,
  showAuthLinks = true,
  showDownload = false,
  authToggle,
}: Props) {
  // Signed-in visitors don't need the auth links or the download CTA; the whole
  // right cluster collapses to a single white button into the product. During the
  // initial (pending) client render `session` is null, which matches the static
  // server HTML, so the signed-out cluster shows first and swaps in on resolve.
  const { data: session } = authClient.useSession();
  const isSignedIn = Boolean(session);

  // Don't show the "Use cases" link when the visitor is already in that section.
  const pathname = usePathname();
  const onUseCases =
    pathname === "/use-cases" || Boolean(pathname?.startsWith("/use-cases/"));

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
          "mx-auto grid w-full max-w-[1400px] grid-cols-[1fr_auto_1fr] items-center rounded-[24px] px-6 py-2 transition-all duration-300 md:px-12 md:py-2.5",
          scrolled
            ? "border border-ink/10 bg-cream/95 shadow-[0_18px_50px_rgba(15,14,13,0.10)] backdrop-blur-md"
            : "border border-transparent bg-transparent shadow-none",
        )}
      >
        <Link
          href={homeHref}
          className="col-start-1 flex items-center gap-0 justify-self-start text-ink no-underline"
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
          <span className="text-2xl font-semibold">{wordmark}</span>
        </Link>
        {/* Center cluster: the product nav lives here so Use cases and the
            Download CTA read as a balanced pair in the middle of the bar. Hidden
            below md, where the header collapses to logo + auth. */}
        <div className="col-start-2 hidden items-center gap-6 justify-self-center md:flex">
          {showNav && !onUseCases ? (
            <Link
              href="/use-cases"
              className="whitespace-nowrap text-sm font-semibold text-ink no-underline"
            >
              Use cases
            </Link>
          ) : null}
          {showDownload && !isSignedIn && !authToggle ? (
            <Link
              href={DONKEY_INSTALL_URL}
              className="inline-flex items-center gap-1 whitespace-nowrap text-sm font-semibold text-ink no-underline"
            >
              Download
              <ArrowRight size={14} />
            </Link>
          ) : null}
        </div>
        <div className="col-start-3 flex items-center gap-[10px] justify-self-end md:gap-4">
          {isSignedIn ? (
            <PillButton href="/app" variant="secondary" size="sm">
              Dashboard
            </PillButton>
          ) : authToggle ? (
            <Link
              href={authToggle.href}
              className="whitespace-nowrap text-sm font-semibold text-ink no-underline"
            >
              {authToggle.label}
            </Link>
          ) : showAuthLinks ? (
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
        </div>
      </div>
    </header>
  );
}
