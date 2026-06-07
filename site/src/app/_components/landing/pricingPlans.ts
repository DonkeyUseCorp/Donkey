import type { BillingPlanKey } from "@/queries/billing";
import type { CardColor } from "@/app/_components/landing/theme";

export type PricingPlanAction =
  | {
      href: string;
      kind: "contact" | "link";
      label: string;
    }
  | {
      kind: "checkout";
      label: string;
      planKey: BillingPlanKey;
    };

export type PricingPlan = {
  action: PricingPlanAction;
  body: string;
  color: CardColor;
  detail: string;
  features: string[];
  name: string;
  price: string;
  tapeColor: CardColor;
  tapePosition?: "left" | "right" | "center";
};

const enterpriseFeatures = [
  "Team rollout planning",
  "Security and deployment review",
  "Custom support around your stack",
];

export const pricingPlans = [
  {
    action: {
      kind: "checkout",
      label: "Start checkout",
      planKey: "pro",
    },
    body: "For people who want Donkey as a daily Mac assistant for planning, app work, and follow-through.",
    color: "cream",
    detail: "For individuals and teams",
    features: [
      "Unlimited usage on Mac (text and voice input)",
      "Prioritized support and feature requests",
      "Early access to new features",
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
    body: "Running Donkey across an org? Reach out and we will figure out what makes sense.",
    color: "coral",
    detail: "built around your team",
    features: enterpriseFeatures,
    name: "Enterprise",
    price: "Let's talk",
    tapeColor: "yellow",
    tapePosition: "right",
  },
] satisfies PricingPlan[];

export const pricingPreviewPlans = [
  {
    ...pricingPlans[0],
    action: {
      href: "/sign-up",
      kind: "link",
      label: "Get Started",
    },
    body: "Start with the self-serve plan when you want Donkey helping with real Mac work.",
  },
  pricingPlans[1],
] satisfies PricingPlan[];
