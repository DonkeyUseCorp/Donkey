import type { Metadata } from "next";
import type { ReactNode } from "react";

import { DashboardShell } from "@/app/dashboard/DashboardShell";

export const metadata: Metadata = {
  title: "Dashboard | Donkey Vision API",
  description: "Manage your Vision API subscription and API keys.",
};

// QueryProvider is mounted once at the root layout, so the dashboard just needs
// its session-guarded shell here.
export default function DashboardLayout({ children }: { children: ReactNode }) {
  return <DashboardShell>{children}</DashboardShell>;
}
