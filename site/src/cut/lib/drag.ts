"use client";

import type React from "react";

interface DragOpts {
  onMove: (dx: number, dy: number, ev: PointerEvent) => void;
  onUp?: (dx: number, dy: number, moved: boolean) => void;
}

/** Pointer-drag helper: tracks deltas from pointerdown until release. */
export function startDrag(e: React.PointerEvent, opts: DragOpts) {
  e.preventDefault();
  e.stopPropagation();
  const startX = e.clientX;
  const startY = e.clientY;
  let moved = false;

  const move = (ev: PointerEvent) => {
    const dx = ev.clientX - startX;
    const dy = ev.clientY - startY;
    if (Math.abs(dx) > 3 || Math.abs(dy) > 3) moved = true;
    opts.onMove(dx, dy, ev);
  };
  const up = (ev: PointerEvent) => {
    window.removeEventListener("pointermove", move);
    window.removeEventListener("pointerup", up);
    window.removeEventListener("pointercancel", up);
    opts.onUp?.(ev.clientX - startX, ev.clientY - startY, moved);
  };
  window.addEventListener("pointermove", move);
  window.addEventListener("pointerup", up);
  window.addEventListener("pointercancel", up);
}
