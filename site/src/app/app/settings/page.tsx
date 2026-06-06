"use client";

import { SubscriptionCard } from "@/app/app/settings/_components/SubscriptionCard";
import { UsageCard } from "@/app/app/settings/_components/UsageCard";

export default function SettingsOverviewPage() {
  return (
    <div className="space-y-8">
      <div>
        <h1 className="text-2xl font-semibold">Overview</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          Your Vision API subscription and usage this billing period.
        </p>
      </div>
      <SubscriptionCard />
      <UsageCard />
    </div>
  );
}
