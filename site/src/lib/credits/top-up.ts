// Client-safe credit top-up constants and pure helpers (no server-only imports),
// shared by the purchase logic, the auto-reload validation, and the settings UI
// so the presets and bounds can never drift between the buttons and the server
// checks. Keep this file free of prisma / Stripe imports.

// Presets drive the quick-buy buttons; the custom field accepts any whole-dollar
// amount in [min, max]. Amounts are whole dollars so they map cleanly to Stripe
// unit_amount cents and the grant ledger.
export const creditTopUpPresetsDollars = [5, 25, 50, 100] as const;
export const creditTopUpMinDollars = 5;
export const creditTopUpMaxDollars = 2_000;

// Stripe metadata "kind" tags that route a completed payment to a credit grant.
export const creditTopUpKind = "credit_topup";
export const creditAutoReloadKind = "credit_topup_autoreload";

export function dollarsToStripeCents(amountDollars: number): number {
  return Math.round(amountDollars * 100);
}
