import type { ReactNode } from "react";

// The /app surface is the signed-in product UI. Unlike the cream landing page,
// it always renders on a white background and uses the same system font as the
// marketing site (the --font-system token shared by the landing page).
export default function AppLayout({ children }: { children: ReactNode }) {
  return (
    <div className="min-h-screen bg-white font-system text-foreground">
      {children}
    </div>
  );
}
