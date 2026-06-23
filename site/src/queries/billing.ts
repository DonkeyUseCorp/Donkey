"use client";

import { useMutation, useQuery } from "@tanstack/react-query";

import { apiFetch } from "@/queries/apiClient";

export const subscriptionQueryKey = ["billing", "subscription"] as const;
export const usageQueryKey = ["billing", "usage"] as const;
export const proSubscriptionQueryKey = ["billing", "pro"] as const;

export type ProSubscription = {
  isActive: boolean;
  status: string | null;
  cancelAtPeriodEnd: boolean;
  currentPeriodEnd: string | null;
  // Included monthly allowance (USD) and how much is left this period.
  monthlyAllowance: string | null;
  allowanceRemaining: string;
};

export function useProSubscription() {
  return useQuery({
    queryFn: () => apiFetch<ProSubscription>("/api/billing/pro"),
    queryKey: proSubscriptionQueryKey,
  });
}

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
  // Extra calls from one-time grants (signup bonus, top-ups), spent after the
  // subscription quota is exhausted.
  extraRemaining: number;
  periodStart: string | null;
  periodEnd: string | null;
  // Recent inference calls across products (app + Vision API), newest first.
  recent: {
    createdAt: string;
    // The app conversation this call belongs to; null for background/warm calls
    // and rows recorded before grouping existed. Drives the grouped rendering.
    conversationId: string | null;
    // "app" = Pro/credit-billed app inference; "vision" = Vision API call.
    product: "app" | "vision";
    requestKind: string;
    model: string;
    status: string;
    // USD cost charged to credits; "included" calls (Vision quota/grants) are 0.
    costCredits: string;
    billingStatus: string;
    errorCode: string | null;
    // Token breakdown that explains the cost.
    usage: {
      inputTokens: number;
      cachedInputTokens: number;
      outputTokens: number;
      totalTokens: number;
      // Images produced by asset_generation calls (priced per image).
      generationCount: number;
      durationMillis: number;
    };
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
