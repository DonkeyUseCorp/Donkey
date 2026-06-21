"use client";

import {
  useOpenBillingPortal,
  useProSubscription,
  useStartCheckout,
} from "@/queries/billing";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { formatUsd } from "@/lib/credits/format-usd";

export function ProCard() {
  const pro = useProSubscription();
  const checkout = useStartCheckout();
  const portal = useOpenBillingPortal();

  if (pro.isLoading) {
    return (
      <Card>
        <CardHeader>
          <Skeleton className="h-6 w-40" />
        </CardHeader>
        <CardContent>
          <Skeleton className="h-16 w-full" />
        </CardContent>
      </Card>
    );
  }

  const data = pro.data;
  const isActive = data?.isActive ?? false;

  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-3">
          Donkey Pro
          {isActive && data ? (
            <Badge variant="default">{data.status}</Badge>
          ) : null}
        </CardTitle>
        <CardDescription>
          A monthly usage allowance for the Donkey app. The included
          allowance is spent before your purchased credits, and resets each
          month.
        </CardDescription>
      </CardHeader>
      <CardContent className="text-sm text-muted-foreground">
        {isActive && data ? (
          <div className="space-y-1">
            <div className="text-foreground">
              {formatUsd(data.allowanceRemaining)} of{" "}
              {formatUsd(data.monthlyAllowance)} included left this month
            </div>
            <div>
              Renews:{" "}
              {data.currentPeriodEnd
                ? new Date(data.currentPeriodEnd).toLocaleDateString()
                : "—"}
            </div>
            {data.cancelAtPeriodEnd ? (
              <div className="text-foreground">
                Cancels at the end of the current period.
              </div>
            ) : null}
          </div>
        ) : (
          <p>
            Subscribe to include a monthly usage allowance. You can still buy
            credits any time; the included allowance is used first.
          </p>
        )}
      </CardContent>
      <CardFooter className="gap-3">
        {isActive ? (
          <Button
            disabled={portal.isPending}
            onClick={() =>
              portal.mutate(undefined, {
                onSuccess: (result) => window.location.assign(result.url),
              })
            }
            variant="secondary"
          >
            {portal.isPending ? "Opening…" : "Manage billing"}
          </Button>
        ) : (
          <Button
            disabled={checkout.isPending}
            onClick={() =>
              checkout.mutate("pro", {
                onSuccess: (result) => window.location.assign(result.url),
              })
            }
          >
            {checkout.isPending ? "Starting…" : "Subscribe to Pro"}
          </Button>
        )}
        {checkout.isError || portal.isError ? (
          <span className="text-sm text-destructive">
            Billing is unavailable right now.
          </span>
        ) : null}
      </CardFooter>
    </Card>
  );
}
