"use client";

import { useEffect, useState } from "react";

type PhaseOpts = {
  step?: number;
  pause?: number;
  reduceMotion?: boolean;
  loop?: boolean;
};

// Shared looping phase driver: p runs 0..total, holds, resets, repeats. With
// reduced motion it skips straight to the finished state.
export function usePhaseLoop(total: number, opts: PhaseOpts = {}) {
  const { step = 330, pause = 1500, reduceMotion = false, loop = true } = opts;
  const [p, setP] = useState(0);
  useEffect(() => {
    if (reduceMotion) return;
    let cur = 0;
    let cancelled = false;
    let id: ReturnType<typeof setTimeout>;
    const tick = () => {
      if (cancelled) return;
      cur += 1;
      setP(cur);
      if (cur >= total) {
        if (loop) {
          id = setTimeout(() => {
            if (cancelled) return;
            cur = 0;
            setP(0);
            id = setTimeout(tick, step);
          }, pause);
        }
      } else {
        id = setTimeout(tick, step);
      }
    };
    id = setTimeout(tick, step);
    return () => {
      cancelled = true;
      clearTimeout(id);
    };
    // Restart only when the reduced-motion preference resolves or flips.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [reduceMotion]);
  return reduceMotion ? total : p;
}
