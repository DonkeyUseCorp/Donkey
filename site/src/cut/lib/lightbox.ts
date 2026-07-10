"use client";

import { create } from "zustand";

// The media lightbox: a full-screen preview opened from a stock tile or a
// generated image. Held in its own store so any tile can open it and a single
// overlay (mounted once in the editor) renders it.

export interface LightboxItem {
  /** Big source. Stock: the static file URL; generated: the still's media URL. */
  src: string;
  /** Generated stills are 8s videos — render the poster frame, not an <img>. */
  isVideo: boolean;
  /** True for real footage (a stock clip): play it with controls instead of
   * showing the poster frame. */
  playable?: boolean;
  name: string;
  /** The generation prompt, when known. */
  prompt: string;
  /** Catalog aspect ("16:9" | "9:16" | "1:1"), when known — sizes the dialog
   * up front so it opens at its final size instead of growing on media load. */
  aspect?: "16:9" | "9:16" | "1:1";
  /** For a project asset, its id (add straight to the timeline); null for a
   * stock image, which the lightbox bakes into a still first. */
  assetId: string | null;
}

interface LightboxState {
  item: LightboxItem | null;
  open: (item: LightboxItem) => void;
  close: () => void;
}

export const useLightbox = create<LightboxState>((set) => ({
  item: null,
  open: (item) => set({ item }),
  close: () => set({ item: null }),
}));
