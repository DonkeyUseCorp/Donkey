"use client";

import { useCallback, useRef, useState } from "react";

/**
 * Whether the element has been scrolled into view at least once. Media
 * previews mount wherever history renders — chat scrollback, attachment
 * chips, render history — so their `src` gates on this: a reload fetches only
 * what's actually on screen instead of every file the project ever made.
 *
 * The ref is a callback ref, so the observer attaches whenever the element
 * actually mounts — including elements that appear only after a later render
 * (a job tile that swaps from its status row to a preview when the render
 * lands). An effect keyed on first render would miss those forever.
 */
export function useInView<T extends HTMLElement>(): [(node: T | null) => void, boolean] {
  const [seen, setSeen] = useState(false);
  const io = useRef<IntersectionObserver | null>(null);
  const ref = useCallback((node: T | null) => {
    io.current?.disconnect();
    io.current = null;
    if (!node) return;
    const obs = new IntersectionObserver(
      (entries) => {
        if (entries.some((e) => e.isIntersecting)) {
          obs.disconnect();
          if (io.current === obs) io.current = null;
          setSeen(true);
        }
      },
      // Start loading just before the tile scrolls in, so it's ready on arrival.
      { rootMargin: "150px" }
    );
    obs.observe(node);
    io.current = obs;
  }, []);
  return [ref, seen];
}
