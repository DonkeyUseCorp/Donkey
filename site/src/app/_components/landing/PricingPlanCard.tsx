"use client";

import { ArrowRight, Check } from "lucide-react";
import { useCallback, useState } from "react";

import {
  PillButton,
  TapedCard,
} from "@/app/_components/landing/LandingPrimitives";
import type { PricingPlan } from "@/app/_components/landing/pricingPlans";
import { useMediaQuery } from "@/app/_components/landing/useMediaQuery";
import { authClient } from "@/lib/auth-client";
import { ApiError } from "@/queries/apiClient";
import { useStartCheckout } from "@/queries/billing";

type Props = {
  plan: PricingPlan;
};

export function PricingPlanCard({ plan }: Props) {
  const isDesktop = useMediaQuery("(min-width: 768px)");
  const [statusMessage, setStatusMessage] = useState<string | null>(null);
  const checkout = useStartCheckout();
  const action = plan.action;

  const handleCheckout = useCallback(async () => {
    if (action.kind !== "checkout") {
      return;
    }

    setStatusMessage(null);

    try {
      const session = await checkout.mutateAsync(action.planKey);
      window.location.assign(session.url);
    } catch (error) {
      if (error instanceof ApiError && error.status === 401) {
        await authClient.signIn.social({
          callbackURL: `/pricing?checkout=${action.planKey}`,
          provider: "google",
        });
        return;
      }

      setStatusMessage("Checkout is not available yet. Please try again soon.");
    }
  }, [action, checkout]);

  const button =
    action.kind === "checkout" ? (
      <PillButton
        disabled={checkout.isPending}
        onClick={handleCheckout}
        variant="dark"
      >
        {checkout.isPending ? "Opening..." : action.label}{" "}
        <ArrowRight size={14} />
      </PillButton>
    ) : (
      <PillButton href={action.href} variant="dark">
        {action.label} <ArrowRight size={14} />
      </PillButton>
    );

  return (
    <TapedCard
      color={plan.color}
      fill
      tapeColor={plan.tapeColor}
      tapePosition={plan.tapePosition}
    >
      <div
        style={{
          boxSizing: "border-box",
          display: "flex",
          flexDirection: "column",
          height: "100%",
          padding: isDesktop ? 36 : 28,
        }}
      >
        <div style={{ fontWeight: 600, fontSize: 22, marginBottom: 18 }}>
          {plan.name}
        </div>
        <div style={{ display: "flex", alignItems: "baseline", gap: 8 }}>
          <span
            style={{
              fontWeight: 600,
              fontSize: isDesktop ? 54 : 42,
              lineHeight: 0.95,
            }}
          >
            {plan.price}
          </span>
        </div>
        <div
          style={{
            fontSize: 13,
            fontWeight: 600,
            color: plan.color === "coral" ? "#201715" : "#444",
            marginBottom: 24,
            marginTop: 10,
          }}
        >
          {plan.detail}
        </div>
        <p
          style={{
            color: plan.color === "coral" ? "#1a1a1a" : "#222",
            fontSize: 15,
            lineHeight: 1.55,
            margin: "0 0 24px",
          }}
        >
          {plan.body}
        </p>
        <div
          style={{
            display: "grid",
            gap: 10,
            marginBottom: 28,
          }}
        >
          {plan.features.map((feature) => (
            <div
              key={feature}
              style={{
                alignItems: "center",
                display: "flex",
                gap: 10,
                fontSize: 14,
                fontWeight: 600,
              }}
            >
              <span
                style={{
                  alignItems: "center",
                  background: "#fff",
                  border: "2px solid #0F0E0D",
                  borderRadius: 999,
                  display: "inline-flex",
                  height: 24,
                  justifyContent: "center",
                  width: 24,
                }}
              >
                <Check size={14} />
              </span>
              <span>{feature}</span>
            </div>
          ))}
        </div>
        <div style={{ marginTop: "auto" }}>
          {button}
          {statusMessage ? (
            <div
              role="status"
              style={{
                color: "#4a403d",
                fontSize: 13,
                fontWeight: 600,
                lineHeight: 1.4,
                marginTop: 14,
              }}
            >
              {statusMessage}
            </div>
          ) : null}
        </div>
      </div>
    </TapedCard>
  );
}
