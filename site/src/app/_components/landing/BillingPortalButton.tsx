"use client";

import { ArrowRight } from "lucide-react";
import { useCallback, useState } from "react";

import { PillButton } from "@/app/_components/landing/LandingPrimitives";
import { authClient } from "@/lib/auth-client";
import { ApiError } from "@/queries/apiClient";
import { useOpenBillingPortal } from "@/queries/billing";

export function BillingPortalButton() {
  const [statusMessage, setStatusMessage] = useState<string | null>(null);
  const portal = useOpenBillingPortal();

  const handleOpenPortal = useCallback(async () => {
    setStatusMessage(null);

    try {
      const session = await portal.mutateAsync();
      window.location.assign(session.url);
    } catch (error) {
      if (error instanceof ApiError && error.status === 401) {
        await authClient.signIn.social({
          callbackURL: "/pricing",
          provider: "google",
        });
        return;
      }

      setStatusMessage("Billing portal is not available yet.");
    }
  }, [portal]);

  return (
    <div>
      <PillButton
        disabled={portal.isPending}
        onClick={handleOpenPortal}
        variant="secondary"
      >
        {portal.isPending ? "Opening..." : "Manage billing"}{" "}
        <ArrowRight size={14} />
      </PillButton>
      {statusMessage ? (
        <div
          role="status"
          style={{
            color: "rgba(255,255,255,0.7)",
            fontSize: 13,
            fontWeight: 600,
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
