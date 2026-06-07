"use client";

import { Link as LinkIcon, Play, Send, type LucideIcon } from "lucide-react";
import Link from "next/link";

type SocialLink = {
  href: string;
  icon: LucideIcon;
  label: string;
};

export function Footer() {
  const socialLinks: SocialLink[] = [
    { href: "https://www.linkedin.com", icon: LinkIcon, label: "LinkedIn" },
    { href: "https://www.youtube.com", icon: Play, label: "YouTube" },
    { href: "https://twitter.com", icon: Send, label: "Twitter" },
  ];

  return (
    <footer className="w-full border-t-2 border-ink px-6 py-16 md:px-12 md:py-[80px]">
      <div className="mx-auto max-w-[1400px]">
        <div className="mb-8 flex flex-wrap items-center gap-4">
          <span className="text-[40px] font-semibold md:text-[48px]">
            donkey
          </span>
          {socialLinks.map((link) => {
            const Icon = link.icon;

            return (
              <a
                aria-label={link.label}
                href={link.href}
                key={link.label}
                className="flex h-10 w-10 items-center justify-center rounded-lg border-2 border-ink bg-white text-ink no-underline"
              >
                <Icon size={18} />
              </a>
            );
          })}
        </div>
        <div className="flex flex-wrap items-end justify-between gap-4 text-[13px] text-[#666]">
          <div>
            <div className="mb-1 font-semibold text-ink">
              david@donkeyuse.com
            </div>
            <div>2026 Donkey, Inc. Made for Macs.</div>
          </div>
          <div className="flex flex-wrap gap-4">
            <Link href="/pricing" className="font-semibold text-ink no-underline">
              Pricing
            </Link>
            <Link href="/sign-in" className="font-semibold text-ink no-underline">
              Log in
            </Link>
            <Link href="/sign-up" className="font-semibold text-ink no-underline">
              Sign up
            </Link>
            <Link href="/privacy" className="font-semibold text-ink no-underline">
              Privacy Policy
            </Link>
            <Link href="/terms" className="font-semibold text-ink no-underline">
              Terms of Use
            </Link>
          </div>
        </div>
      </div>
    </footer>
  );
}
