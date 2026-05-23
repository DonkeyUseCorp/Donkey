import type { Metadata } from "next";

import { Footer } from "@/app/_components/landing/Footer";
import { TopNav } from "@/app/_components/landing/TopNav";
import { GITHUB_REPO_URL } from "@/app/_components/landing/data";
import { BG, BLACK } from "@/app/_components/landing/theme";
import { InstallInstructions } from "@/app/install/_components/InstallInstructions";

export const dynamic = "force-static";

export const metadata: Metadata = {
  title: "Install Donkey",
  description: "Download Donkey for macOS and install it with the standard drag-to-Applications flow.",
};

export default function InstallPage() {
  return (
    <main
      style={{
        minHeight: "100vh",
        background: BG,
        color: BLACK,
        fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
        WebkitFontSmoothing: "antialiased",
      }}
    >
      <TopNav ctaHref={GITHUB_REPO_URL} ctaLabel="Download" />
      <InstallInstructions />
      <Footer />
    </main>
  );
}
