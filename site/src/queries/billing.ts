"use client";

import { useMutation, useQuery } from "@tanstack/react-query";

import { apiFetch } from "@/queries/apiClient";

export const subscriptionQueryKey = ["billing", "subscription"] as const;
export const usageQueryKey = ["billing", "usage"] as const;

// Plans that the checkout route understands. Only "vision" is self-serve today;
// "pro" (the Mac app plan) is accepted by the landing card but the route returns
// "not available" until it is wired to Stripe.
export type BillingPlanKey = "vision" | "pro";

export type VisionSubscription = {
  status: string;
  isActive: boolean;
  planKey: string;
  monthlyCallQuota: number;
  currentPeriodEnd: string | null;
  cancelAtPeriodEnd: boolean;
};

export type VisionUsage = {
  used: number;
  limit: number;
  remaining: number;
  periodStart: string | null;
  periodEnd: string | null;
  recent: {
    createdAt: string;
    model: string;
    requestKind: string;
    status: string;
  }[];
};

export function useSubscription() {
  return useQuery({
    queryFn: () =>
      apiFetch<{ subscription: VisionSubscription | null }>(
        "/api/billing/subscription",
      ).then((response) => response.subscription),
    queryKey: subscriptionQueryKey,
  });
}

export function useUsage() {
  return useQuery({
    queryFn: () => apiFetch<VisionUsage>("/api/billing/usage"),
    queryKey: usageQueryKey,
  });
}

// Mutations return the Stripe URL; the caller redirects the browser. We don't
// invalidate here because the user leaves the page for Stripe.
export function useStartCheckout() {
  return useMutation({
    mutationFn: (planKey?: BillingPlanKey) =>
      apiFetch<{ url: string }>("/api/billing/checkout", {
        body: JSON.stringify({ planKey: planKey ?? "vision" }),
        method: "POST",
      }),
  });
}

export function useOpenBillingPortal() {
  return useMutation({
    mutationFn: () =>
      apiFetch<{ url: string }>("/api/billing/portal", { method: "POST" }),
  });
}
