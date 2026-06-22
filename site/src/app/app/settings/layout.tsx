import type { Metadata } from "next";
import type { ReactNode } from "react";

import { SettingsShell } from "@/app/app/settings/SettingsShell";

export const metadata: Metadata = {
  title: "Settings | Donkey Vision API",
  description: "Manage your Vision API subscription and API keys.",
};

// QueryProvider is mounted once at the root layout, so the settings UI just needs
// its session-guarded shell here.
export default function SettingsLayout({ children }: { children: ReactNode }) {
  return <SettingsShell>{children}</SettingsShell>;
}
