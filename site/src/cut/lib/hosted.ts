"use client";

import { useEffect } from "react";
import { create } from "zustand";

// Donkey's hosted inference routes, called from the page with the user's
// session and credits (the one hosted carve-out on the otherwise local-only
// Cut page). Shared by media generation, prompt composition, and AI chat.

const CLIENT_ID = "donkey-cut";

const OUT_KEY = "cut-credits-out";

/** Whether the account balance is known to be empty: the last hosted call
 * bounced with a 402. Set and cleared by `hostedPost` — the single chokepoint
 * for hosted calls — and persisted so a reload keeps the composer's credits
 * tab up until a call goes through again. */
export const useOutOfCredits = create<{ out: boolean }>(() => ({
  out: typeof window !== "undefined" && safeRead() === "1",
}));

function safeRead(): string | null {
  try {
    return localStorage.getItem(OUT_KEY);
  } catch {
    return null;
  }
}

function setOut(out: boolean) {
  useOutOfCredits.setState({ out });
  try {
    if (out) localStorage.setItem(OUT_KEY, "1");
    else localStorage.removeItem(OUT_KEY);
  } catch {
    // Storage blocked — the flag just won't survive a reload.
  }
}

function noteBalance(res: Response) {
  if (res.status === 402 || res.ok) setOut(res.status === 402);
}

// One re-check in flight at a time; focus/visibility events can fire together.
let rechecking: Promise<void> | null = null;

/** While flagged out, ask the balance route directly: a top-up happens on the
 * settings page, so waiting for the next hosted call would leave the credits
 * tab up after the user already paid. Any failure leaves the flag as is. */
export function recheckCredits(): Promise<void> {
  if (!useOutOfCredits.getState().out) return Promise.resolve();
  rechecking ??= fetch("/api/credits/balance", { cache: "no-store" })
    .then(async (res) => {
      if (!res.ok) return;
      const body = (await res.json()) as { balanceMicros?: string };
      if (Number(body.balanceMicros ?? 0) > 0) setOut(false);
    })
    .catch(() => {})
    .finally(() => {
      rechecking = null;
    });
  return rechecking;
}

/** Keep the out-of-credits flag honest while a surface shows it: re-check on
 * mount and whenever the tab regains focus, so reloading credits in another
 * tab clears the composer's credits tab without a hosted call. */
export function useCreditsRecheck(): void {
  const out = useOutOfCredits((s) => s.out);
  useEffect(() => {
    if (!out) return;
    void recheckCredits();
    const onFocus = () => void recheckCredits();
    const onVisible = () => {
      if (document.visibilityState === "visible") void recheckCredits();
    };
    window.addEventListener("focus", onFocus);
    document.addEventListener("visibilitychange", onVisible);
    return () => {
      window.removeEventListener("focus", onFocus);
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, [out]);
}

/** POST one of Donkey's hosted inference routes with the user's session. */
export const hostedPost = async (path: string, body: unknown, signal?: AbortSignal) => {
  const res = await fetch(path, {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-donkey-client-id": CLIENT_ID },
    body: JSON.stringify(body),
    signal,
  });
  noteBalance(res);
  return res;
};
