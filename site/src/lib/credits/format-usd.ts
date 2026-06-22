// Shared USD formatter for the settings cards so money renders identically
// everywhere. null/undefined → an em dash (no value yet); a non-numeric string
// → "$0.00"; otherwise a localized currency string.
export function formatUsd(value: string | null | undefined): string {
  if (value === null || value === undefined) {
    return "—";
  }
  const parsed = Number.parseFloat(value);
  if (!Number.isFinite(parsed)) {
    return "$0.00";
  }
  return parsed.toLocaleString("en-US", { currency: "USD", style: "currency" });
}
