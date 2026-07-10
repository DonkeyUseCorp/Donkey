"use client";

import { useEffect, useState } from "react";
import { create } from "zustand";
import type { AssetRef, AssetRefScope } from "./assetRef";

// Clicking a reference token (chat message, attachment chip) jumps back to the
// original asset: the side panel switches to the owning tab (Media, Library,
// or Image), the card scrolls into view, and it flashes. The store carries the
// one-shot target; panels react to `seq` for the tab/folder switch and cards
// use `useRevealFlash` for the scroll + flash.

interface RefRevealState {
  target: AssetRef | null;
  /** Bumps per reveal so re-revealing the same asset still fires effects. */
  seq: number;
  /** Timestamp of the reveal; effects ignore stale targets on remount. */
  at: number;
  reveal: (ref: AssetRef) => void;
}

export const useRefReveal = create<RefRevealState>((set) => ({
  target: null,
  seq: 0,
  at: 0,
  reveal: (ref) => set((s) => ({ target: ref, seq: s.seq + 1, at: Date.now() })),
}));

export const revealRef = (ref: AssetRef) => useRefReveal.getState().reveal(ref);

/** How long a reveal stays actionable — long enough to survive the tab switch
 * and mount, short enough that a remount later doesn't replay it. */
const FRESH_MS = 3000;

/** Card-side reveal handling: attach the returned ref callback to the card's
 * element; when this asset becomes the reveal target the card scrolls into
 * view and `flash` turns on briefly for a highlight style. */
export function useRevealFlash(
  scope: AssetRefScope,
  id: string
): { flash: boolean; attachReveal: (el: HTMLElement | null) => void } {
  const [el, setEl] = useState<HTMLElement | null>(null);
  const [flash, setFlash] = useState(false);
  const seq = useRefReveal((s) =>
    s.target && s.target.scope === scope && s.target.id === id ? s.seq : 0
  );

  useEffect(() => {
    if (!seq || !el) return;
    if (Date.now() - useRefReveal.getState().at > FRESH_MS) return;
    el.scrollIntoView({ block: "center", behavior: "smooth" });
    // Flash on a deferred tick — a sync setState in an effect cascades renders.
    const on = setTimeout(() => setFlash(true), 0);
    const off = setTimeout(() => setFlash(false), 1600);
    return () => {
      clearTimeout(on);
      clearTimeout(off);
    };
  }, [seq, el]);

  return { flash, attachReveal: setEl };
}

/** Panel-side reveal handling: runs `onReveal` once per fresh reveal so the
 * panel can switch tabs, open the owning folder, or change category views. */
export function useRevealEffect(onReveal: (ref: AssetRef) => void) {
  const seq = useRefReveal((s) => s.seq);
  useEffect(() => {
    if (!seq) return;
    const { target, at } = useRefReveal.getState();
    if (!target || Date.now() - at > FRESH_MS) return;
    onReveal(target);
    // Re-run on each reveal only; the callback is read fresh per firing.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [seq]);
}
