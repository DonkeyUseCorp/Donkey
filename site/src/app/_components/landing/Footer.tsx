"use client";

import { Link as LinkIcon, Play, Send, type LucideIcon } from "lucide-react";
import Link from "next/link";

type SocialLink = {
  href: string;
  icon: LucideIcon;
  label: string;
};

type FooterLink = { href: string; label: string };
type FooterColumn = { title: string; links: FooterLink[] };

export function Footer() {
  const socialLinks: SocialLink[] = [
    { href: "https://www.linkedin.com", icon: LinkIcon, label: "LinkedIn" },
    { href: "https://www.youtube.com", icon: Play, label: "YouTube" },
    { href: "https://twitter.com", icon: Send, label: "Twitter" },
  ];

  // Each entry renders as its own titled column in the footer.
  const linkGroups: FooterColumn[] = [
    {
      title: "Product",
      links: [
        { href: "/install", label: "Donkey for Mac" },
        { href: "/donkeyvision", label: "Donkey Vision API" },
      ],
    },
    {
      title: "Account",
      links: [
        { href: "/pricing", label: "Pricing" },
        { href: "/sign-in", label: "Log in" },
        { href: "/sign-up", label: "Sign up" },
      ],
    },
    {
      title: "Legal",
      links: [
        { href: "/privacy", label: "Privacy Policy" },
        { href: "/terms", label: "Terms of Use" },
      ],
    },
  ];

  return (
    <footer className="w-full border-t-2 border-ink px-6 py-16 md:px-12 md:py-[80px]">
      <div className="mx-auto flex max-w-[1400px] flex-col gap-12 md:flex-row md:flex-wrap md:gap-x-24">
        <div className="min-w-[240px] max-w-sm flex-1">
          <div className="mb-6 flex flex-wrap items-center gap-4">
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
          <p className="text-[15px] font-semibold text-ink">
            Need help? Email us at{" "}
            <a
              href="mailto:david@donkeyuse.com"
              className="underline underline-offset-2"
            >
              david@donkeyuse.com
            </a>
          </p>
          <p className="mt-6 text-[13px] text-[#666]">
            2026 Donkey, Inc. Made for Macs.
          </p>
        </div>
        <div className="flex flex-1 flex-col gap-10 sm:flex-row sm:flex-wrap sm:gap-x-16 sm:gap-y-12 md:gap-x-20">
          {linkGroups.map((group) => (
            <div key={group.title} className="flex min-w-[140px] flex-col gap-4">
              <div className="text-[15px] font-semibold text-ink">
                {group.title}
              </div>
              <div className="flex flex-col gap-3">
                {group.links.map((link) => (
                  <Link
                    key={link.href}
                    href={link.href}
                    className="text-[15px] text-[#666] no-underline transition-colors hover:text-ink"
                  >
                    {link.label}
                  </Link>
                ))}
              </div>
            </div>
          ))}
        </div>
      </div>
    </footer>
  );
}
