"use client";

import { ArrowRight } from "lucide-react";
import { useCallback, useState } from "react";

import {
  BillingApiError,
  createBillingPortalSession,
} from "@/app/api-clients/billingApi";
import { PillButton } from "@/app/_components/landing/LandingPrimitives";
import { authClient } from "@/lib/auth-client";

export function BillingPortalButton() {
  const [isPending, setIsPending] = useState(false);
  const [statusMessage, setStatusMessage] = useState<string | null>(null);

  const handleOpenPortal = useCallback(async () => {
    setIsPending(true);
    setStatusMessage(null);

    try {
      const session = await createBillingPortalSession();
      window.location.assign(session.url);
    } catch (error) {
      if (
        error instanceof BillingApiError &&
        error.code === "unauthorized"
      ) {
        await authClient.signIn.social({
          callbackURL: "/pricing",
          provider: "google",
        });
        return;
      }

      if (error instanceof BillingApiError && error.code === "not-found") {
        setStatusMessage("Billing portal is not available yet.");
      } else {
        setStatusMessage("Billing portal is not available yet.");
      }
    } finally {
      setIsPending(false);
    }
  }, []);

  return (
    <div>
      <PillButton disabled={isPending} onClick={handleOpenPortal} variant="secondary">
        {isPending ? "Opening..." : "Manage billing"} <ArrowRight size={14} />
      </PillButton>
      {statusMessage ? (
        <div
          role="status"
          style={{
            color: "rgba(255,255,255,0.7)",
            fontSize: 13,
            fontWeight: 700,
            lineHeight: 1.4,
            marginTop: 12,
          }}
        >
          {statusMessage}
        </div>
      ) : null}
    </div>
  );
}
