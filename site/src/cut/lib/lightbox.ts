"use client";

import { create } from "zustand";
import type { AssetRef } from "./assetRef";

// The asset lightbox: a full-screen viewer opened from stock tiles, generated
// media, and chat asset cards. Held in its own store so any surface can open
// it and a single overlay (mounted once in the editor) renders it.

export interface LightboxItem {
  kind: "video" | "image" | "audio" | "text";
  /** Fetchable source for the media or file. */
  src: string;
  name: string;
  /** The generation prompt, when known. */
  prompt: string;
  /** Catalog aspect ("16:9" | "9:16" | "1:1"), when known — sizes the dialog
   * up front so it opens at its final size instead of growing on media load. */
  aspect?: "16:9" | "9:16" | "1:1";
  /** For a project asset, its id (add straight to the timeline); null for a
   * stock item, which the lightbox imports first. */
  assetId: string | null;
}

/** The lightbox view of an asset ref — how chat cards and attachment chips
 * open the big version of whatever they show. */
export const lightboxItemFromRef = (ref: AssetRef): LightboxItem => ({
  kind: ref.kind,
  src: ref.url,
  name: ref.name,
  prompt: "",
  assetId: ref.scope === "project" ? ref.id : null,
});

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
