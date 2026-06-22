"use client";

import {
  useOpenBillingPortal,
  useStartCheckout,
  useSubscription,
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

export function SubscriptionCard() {
  const subscription = useSubscription();
  const checkout = useStartCheckout();
  const portal = useOpenBillingPortal();

  if (subscription.isLoading) {
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

  const data = subscription.data;
  const isActive = data?.isActive ?? false;

  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-3">
          Vision API plan
          {data ? (
            <Badge variant={isActive ? "default" : "secondary"}>
              {data.status}
            </Badge>
          ) : null}
        </CardTitle>
        <CardDescription>
          {data
            ? `${data.monthlyCallQuota.toLocaleString()} API calls per month.`
            : "$50/month · 5,000 API calls per month · 3 requests/second."}
        </CardDescription>
      </CardHeader>
      <CardContent className="text-sm text-muted-foreground">
        {data ? (
          <div className="space-y-1">
            <div>
              Renews / ends:{" "}
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
            Subscribe for a monthly quota, or get started with your free calls.
          </p>
        )}
      </CardContent>
      <CardFooter className="gap-3">
        {data ? (
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
              checkout.mutate(undefined, {
                onSuccess: (result) => window.location.assign(result.url),
              })
            }
          >
            {checkout.isPending ? "Starting…" : "Subscribe — $50/mo"}
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
