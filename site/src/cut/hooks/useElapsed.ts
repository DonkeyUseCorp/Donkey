"use client";

import { useEffect, useState } from "react";
import { formatElapsed } from "../lib/time";

// Live elapsed readouts for long-running work (renders, exports, imports,
// transcription). Every surface that spins for more than a moment shows one
// beside its label, so the user always sees time passing.

/** Ticking "m:ss" since `startedAt` (ms epoch), or null without one. The
 * first second may read 0:00 — the clock advances only from its interval,
 * never synchronously in render. */
export function useElapsed(startedAt: number | null | undefined): string | null {
  const active = startedAt != null;
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    if (!active) return;
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, [active]);
  return active ? formatElapsed(now - startedAt) : null;
}
