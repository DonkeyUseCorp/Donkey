"use client";

import { useState } from "react";
import { useElapsed } from "../hooks/useElapsed";

/** A ticking "m:ss" that starts counting when it mounts — drop it beside a
 * long-running spinner label ("Rendering… 0:42") that renders only while the
 * work runs. Surfaces with a real start timestamp should use the useElapsed
 * hook instead so a remount doesn't reset the clock. */
export function LiveElapsed({ className }: { className?: string }) {
  const [startedAt] = useState(() => Date.now());
  const elapsed = useElapsed(startedAt);
  return elapsed ? (
    <span className={className ?? "tabular-nums opacity-80"}>{elapsed}</span>
  ) : null;
}
