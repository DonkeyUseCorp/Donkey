import type { ReactNode } from "react";
import { cn } from "@/lib/utils";

/** Heading for a settings/config section — the one look used everywhere in Cut. */
export function SectionTitle({ children, className }: { children: ReactNode; className?: string }) {
  return <div className={cn("text-xs font-semibold text-muted-foreground", className)}>{children}</div>;
}
