import { BrowserUse } from "browser-use-sdk/v3";

import { browserUseModels } from "@/lib/browser/models";

export { browserUseDefaultMaxCostUsd } from "@/lib/browser/pricing";

let cached: BrowserUse | null = null;

/// Lazy, cached Browser Use Cloud client. BROWSER_USE_API_KEY is a backend secret
/// that is always configured in our environments; it never reaches the app.
export function getBrowserUse(): BrowserUse {
  cached ??= new BrowserUse({ apiKey: process.env.BROWSER_USE_API_KEY });
  return cached;
}

/// Provider/model identity for credit accounting (see provider-pricing.ts).
export const browserUseProvider = "browser-use";
/// The default agent model for web.automate tasks.
export const browserUseDefaultModel = browserUseModels.agent;

/// Browser Use session lifecycle terminal states (created → idle → running →
/// these). A run is done — and billable — once it reaches one of these.
export function isTerminalBrowserStatus(status: string): boolean {
  return status === "stopped" || status === "timed_out" || status === "error";
}
