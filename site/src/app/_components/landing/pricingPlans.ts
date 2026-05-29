import type { BillingPlanKey } from "@/app/api-clients/billingApi";
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
    detail: "More done with AI on your Mac",
    features: [
      "Advanced reasoning for Mac tasks",
      "Local app actions and workflow runs",
      "Help across everyday Mac apps",
      "Review steps before important actions",
      "Simple billing and account access",
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
      href: "/pricing",
      kind: "link",
      label: "See Pro",
    },
    body: "Start with the self-serve plan when you want Donkey helping with real Mac work.",
    detail: "More done with AI on your Mac",
  },
  pricingPlans[1],
] satisfies PricingPlan[];
