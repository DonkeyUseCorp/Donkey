"use client";

import { CreditsCard } from "@/app/app/settings/_components/CreditsCard";
import { ProCard } from "@/app/app/settings/_components/ProCard";
import { SubscriptionCard } from "@/app/app/settings/_components/SubscriptionCard";
import { SuperuserCreditsCard } from "@/app/app/settings/_components/SuperuserCreditsCard";
import { UsageCard } from "@/app/app/settings/_components/UsageCard";

export default function SettingsOverviewPage() {
  return (
    <div className="space-y-8">
      <div>
        <h1 className="text-2xl font-semibold">Overview</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          Your subscriptions, credit balance, and
          usage this billing period.
        </p>
      </div>
      <ProCard />
      <CreditsCard />
      <SubscriptionCard />
      <UsageCard />
      <SuperuserCreditsCard />
    </div>
  );
}
