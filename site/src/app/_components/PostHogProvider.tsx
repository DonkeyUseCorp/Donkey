"use client";

import posthog from "posthog-js";
import { PostHogProvider as Provider } from "@posthog/react";
import type { ReactNode } from "react";

export function PostHogProvider({ children }: { children: ReactNode }) {
  return <Provider client={posthog}>{children}</Provider>;
}
