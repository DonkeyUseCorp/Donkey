"use client";

import Link from "next/link";

import { GITHUB_REPO_URL } from "@/app/_components/landing/data";

// Cut's own footer: the shared landing Footer links routes that don't exist on
// donkeycut.com (/sign-in, /use-cases, /donkeyvision), so this one carries only
// links that resolve on both hosts.
export function CutFooter() {
  const links = [
    { href: GITHUB_REPO_URL, label: "GitHub" },
    { href: "https://donkeyuse.com", label: "Donkey" },
    { href: "/privacy", label: "Privacy Policy" },
    { href: "/terms", label: "Terms of Use" },
  ];

  return (
    <footer className="w-full border-t-2 border-ink py-16 md:py-[80px]">
      <div className="mx-auto flex max-w-[1400px] flex-col gap-10 px-6 md:flex-row md:items-start md:justify-between md:px-12">
        <div className="max-w-sm">
          <div className="text-[40px] font-semibold text-ink md:text-[48px]">
            Donkey Cut
          </div>
          <p className="mt-4 text-[15px] font-semibold text-ink">
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
        <div className="flex flex-col gap-3">
          {links.map((link) =>
            link.href.startsWith("/") ? (
              <Link
                key={link.label}
                href={link.href}
                className="text-[15px] text-[#666] no-underline transition-colors hover:text-ink"
              >
                {link.label}
              </Link>
            ) : (
              <a
                key={link.label}
                href={link.href}
                className="text-[15px] text-[#666] no-underline transition-colors hover:text-ink"
              >
                {link.label}
              </a>
            ),
          )}
        </div>
      </div>
    </footer>
  );
}
