"use client";

import { useEffect, useRef, useState, type RefObject } from "react";

/**
 * Whether the element has been scrolled into view at least once. Media
 * previews mount wherever history renders — chat scrollback, attachment
 * chips, render history — so their `src` gates on this: a reload fetches only
 * what's actually on screen instead of every file the project ever made.
 */
export function useInView<T extends HTMLElement>(): [RefObject<T | null>, boolean] {
  const ref = useRef<T>(null);
  const [seen, setSeen] = useState(false);
  useEffect(() => {
    if (seen) return;
    const el = ref.current;
    if (!el) return;
    const io = new IntersectionObserver(
      (entries) => {
        if (entries.some((e) => e.isIntersecting)) setSeen(true);
      },
      // Start loading just before the tile scrolls in, so it's ready on arrival.
      { rootMargin: "150px" }
    );
    io.observe(el);
    return () => io.disconnect();
  }, [seen]);
  return [ref, seen];
}
