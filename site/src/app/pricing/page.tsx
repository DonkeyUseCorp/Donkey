import type { Metadata } from "next";

import { PricingPage } from "@/app/_components/landing/PricingPage";

export const metadata: Metadata = {
  title: "Pricing | Donkey",
  description: "Pick a Donkey plan for self-serve Pro billing or team rollout.",
};

export default function Page() {
  return <PricingPage />;
}
