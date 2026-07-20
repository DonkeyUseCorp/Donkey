import type { PricingPlan } from "@/app/_components/landing/pricingPlans";

// Cut's two tiers: the editor itself is free and local; Pro adds monthly AI
// generation credits. `root` prefixes in-app links ("" on donkeycut.com,
// "/cut" in dev) so the cards work on either host.
export function cutPricingPlans(root: string): PricingPlan[] {
  return [
    {
      action: {
        href: `${root}/app`,
        kind: "link",
        label: "Start a new project",
      },
      body: "The whole editor, running on your own hardware.",
      color: "cream",
      detail: "No account needed",
      features: [
        "Full access to the video editor",
        "Import, export, and local transcription",
        "Connect your Claude or Codex subscription",
      ],
      name: "Free",
      price: "$0",
      tapeColor: "coral",
    },
    {
      action: {
        href: "/app/settings",
        kind: "link",
        label: "Get Pro",
      },
      body: "For editors who want AI generation in the timeline.",
      color: "coral",
      detail: "For individuals",
      features: [
        "Everything in Free",
        "Generous AI credits every month",
        "Image, video, voiceover, and music generation",
      ],
      name: "Pro",
      price: "$20/month",
      tapeColor: "yellow",
      tapePosition: "right",
    },
  ];
}
