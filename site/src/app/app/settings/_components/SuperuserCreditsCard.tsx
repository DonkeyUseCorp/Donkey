"use client";

import { useState } from "react";

import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { useAccount, useGrantCredits } from "@/queries/credits";

// Super users top up in $100 increments — the manual grant route caps a single
// grant at $100, so larger top-ups are repeated clicks.
const incrementDollars = 100;

export function SuperuserCreditsCard() {
  const account = useAccount();
  const grant = useGrantCredits();
  const [email, setEmail] = useState("");
  const [lastResult, setLastResult] = useState<string | null>(null);

  // Render nothing for non-super users (and while we don't yet know).
  if (!account.data?.superUser) {
    return null;
  }

  const grantToSelf = () => {
    setLastResult(null);
    grant.mutate(
      { amountDollars: incrementDollars, userId: account.data.userId },
      {
        onSuccess: (result) =>
          setLastResult(
            `Added $${incrementDollars} to ${result.targetUser.email} — new balance $${result.balance.balance}.`,
          ),
      },
    );
  };

  const grantToEmail = () => {
    if (!email.trim()) {
      return;
    }
    setLastResult(null);
    grant.mutate(
      { amountDollars: incrementDollars, email: email.trim() },
      {
        onSuccess: (result) => {
          setLastResult(
            `Added $${incrementDollars} to ${result.targetUser.email} — new balance $${result.balance.balance}.`,
          );
          setEmail("");
        },
      },
    );
  };

  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2">
          Super user · Credits
        </CardTitle>
        <CardDescription>
          Grant credits in ${incrementDollars} increments. Visible to super users
          only.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-5">
        <div>
          <Button disabled={grant.isPending} onClick={grantToSelf}>
            {grant.isPending ? "Adding…" : `+ $${incrementDollars} to my account`}
          </Button>
        </div>

        <div className="space-y-2 border-t pt-5">
          <Label htmlFor="grant-email">Grant to a user</Label>
          <div className="flex items-end gap-2">
            <Input
              className="max-w-xs"
              id="grant-email"
              onChange={(event) => setEmail(event.target.value)}
              placeholder="user@example.com"
              type="email"
              value={email}
            />
            <Button
              disabled={grant.isPending || !email.trim()}
              onClick={grantToEmail}
              variant="secondary"
            >
              Grant ${incrementDollars}
            </Button>
          </div>
        </div>

        {lastResult ? (
          <p className="text-sm text-muted-foreground">{lastResult}</p>
        ) : null}
        {grant.isError ? (
          <p className="text-sm text-destructive">
            Grant failed. Check the email and try again.
          </p>
        ) : null}
      </CardContent>
    </Card>
  );
}
