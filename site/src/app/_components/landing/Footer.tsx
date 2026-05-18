"use client";

import { Link, Play, Send, type LucideIcon } from "lucide-react";

import { useMediaQuery } from "@/app/_components/landing/useMediaQuery";
import { BLACK } from "@/app/_components/landing/theme";

type SocialLink = {
  href: string;
  icon: LucideIcon;
  label: string;
};

export function Footer() {
  const isDesktop = useMediaQuery("(min-width: 768px)");
  const socialLinks: SocialLink[] = [
    { href: "https://www.linkedin.com", icon: Link, label: "LinkedIn" },
    { href: "https://www.youtube.com", icon: Play, label: "YouTube" },
    { href: "https://twitter.com", icon: Send, label: "Twitter" },
  ];

  return (
    <footer
      style={{
        borderTop: `2px solid ${BLACK}`,
        padding: isDesktop ? "80px 48px" : "64px 24px",
      }}
    >
      <div style={{ maxWidth: 1400, margin: "0 auto" }}>
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: 16,
            marginBottom: 32,
            flexWrap: "wrap",
          }}
        >
          <span style={{ fontWeight: 900, fontSize: isDesktop ? 48 : 40 }}>
            donkey
          </span>
          {socialLinks.map((link) => {
            const Icon = link.icon;

            return (
              <a
                aria-label={link.label}
                href={link.href}
                key={link.label}
                style={{
                  width: 40,
                  height: 40,
                  borderRadius: 8,
                  border: `2px solid ${BLACK}`,
                  display: "flex",
                  alignItems: "center",
                  justifyContent: "center",
                  color: BLACK,
                  textDecoration: "none",
                  background: "#fff",
                }}
              >
                <Icon size={18} />
              </a>
            );
          })}
        </div>
        <div
          style={{
            display: "flex",
            alignItems: "flex-end",
            justifyContent: "space-between",
            gap: 16,
            flexWrap: "wrap",
            fontSize: 13,
            color: "#666",
          }}
        >
          <div>
            <div style={{ fontWeight: 800, color: BLACK, marginBottom: 4 }}>
              david@donkeyuse.com
            </div>
            <div>2026 Donkey, Inc. Made for Macs.</div>
          </div>
        </div>
      </div>
    </footer>
  );
}
