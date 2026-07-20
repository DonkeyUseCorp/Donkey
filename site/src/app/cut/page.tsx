import type { Metadata } from "next";
import { headers } from "next/headers";

import { CutLanding } from "@/app/cut/_components/landing/CutLanding";
import {
  DONKEYCUT_CANONICAL,
  isDonkeycutHost,
  isLocalHost,
} from "@/cut/lib/hosts";

export const metadata: Metadata = {
  title: "Donkey Cut — the AI video editor on your Mac",
  description:
    "Cut video with AI on your own Mac. Generate images, clips, voiceover, and music in the timeline; every edit and export renders locally.",
  alternates: { canonical: `${DONKEYCUT_CANONICAL}/` },
  openGraph: {
    title: "Donkey Cut — the AI video editor on your Mac",
    description:
      "Cut video with AI on your own Mac. Generation in the timeline, editing and export fully local.",
    url: `${DONKEYCUT_CANONICAL}/`,
    siteName: "Donkey Cut",
    type: "website",
    images: [{ url: "/cut/landing/og.png", width: 1200, height: 630 }],
  },
  twitter: {
    card: "summary_large_image",
    title: "Donkey Cut — the AI video editor on your Mac",
    description:
      "Cut video with AI on your own Mac. Generation in the timeline, editing and export fully local.",
    images: ["/cut/landing/og.png"],
  },
};

// The Cut marketing landing: "/" on donkeycut.com and in local dev (both
// rewrite "/…" → "/cut/…"), /cut on the hosted apex. `root` prefixes in-page
// links to the app so they resolve on any host.
export default async function CutLandingPage() {
  const host = (await headers()).get("host");
  const root = isDonkeycutHost(host) || isLocalHost(host) ? "" : "/cut";
  return <CutLanding root={root} />;
}
