import type { PricingPlan } from "@/app/_components/landing/pricingPlans";

// Cut's pricing preview: editing is free and local; the paid plan covers the
// hosted AI generation that runs on Donkey credits. Actions avoid /sign-up —
// that route does not exist on donkeycut.com; the download carries onboarding.
export const cutPricingPlans = [
  {
    action: {
      href: "/install",
      kind: "link",
      label: "Download for Mac",
    },
    body: "Editing, timeline, and export are free and run entirely on your Mac. Pro covers the AI: image, video, voiceover, and music generation in the editor.",
    color: "cream",
    detail: "For individuals",
    features: [
      "Unlimited local editing and export",
      "AI generation credits every month",
      "Prioritized support and feature requests",
    ],
    name: "Pro",
    price: "$20/month",
    tapeColor: "coral",
  },
  {
    action: {
      href: "mailto:david@donkeyuse.com",
      kind: "contact",
      label: "Contact us",
    },
    body: "Cutting video across a team? Reach out and we will figure out what makes sense.",
    color: "coral",
    detail: "built around your team",
    features: [
      "Team rollout planning",
      "Security and deployment review",
      "Custom support around your stack",
    ],
    name: "Enterprise",
    price: "Let's talk",
    tapeColor: "yellow",
    tapePosition: "right",
  },
] satisfies PricingPlan[];
