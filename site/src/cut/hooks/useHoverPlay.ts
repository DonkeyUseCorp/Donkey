"use client";

import { useRef } from "react";

/**
 * Hover-to-play for a muted <video> poster: entering plays with sound, leaving
 * pauses, re-mutes, and returns to the first frame. Sound needs a prior page
 * interaction; if the browser refuses it, playback falls back to silent rather
 * than not starting at all. Attach `ref` to the <video> and spread `handlers`
 * on the hover target (the tile, not the video, so scrims stay hoverable).
 */
export function useHoverPlay() {
  const ref = useRef<HTMLVideoElement>(null);
  const handlers = {
    onMouseEnter: () => {
      const v = ref.current;
      if (!v) return;
      v.muted = false;
      void v.play().catch(() => {
        v.muted = true;
        void v.play().catch(() => {});
      });
    },
    onMouseLeave: () => {
      const v = ref.current;
      if (!v) return;
      v.pause();
      v.muted = true;
      v.currentTime = 0.1;
    },
  };
  return { ref, handlers };
}
