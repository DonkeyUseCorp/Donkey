"use client";

import { create } from "zustand";
import { addRefOnce, sameRef, type AssetRef } from "./assetRef";

// The generate-image panel's state, shared between the stock browser (which
// loads a stock image's saved prompt into it on click) and the always-on
// generate panel that sits beside the browser in the Image tab.

/** The shape the next generated image is composed in. */
export type ImageAspect = "16:9" | "9:16" | "1:1";

export const IMAGE_ASPECT_LABEL: Record<ImageAspect, string> = {
  "16:9": "Landscape (16:9)",
  "9:16": "Portrait (9:16)",
  "1:1": "Square (1:1)",
};

interface ImageGenState {
  prompt: string;
  /** The shape the next generation is composed in. */
  aspect: ImageAspect;
  /** Visual references attached to the next generation (dragged in or picked
   * via @name mentions resolved on send). */
  refs: AssetRef[];
  /** Load a starting prompt into the panel (a stock image's saved prompt, or
   * "" for a blank generation). Resets any attached references. */
  openWith: (prompt: string) => void;
  setPrompt: (prompt: string) => void;
  setAspect: (aspect: ImageAspect) => void;
  addRef: (ref: AssetRef) => void;
  removeRef: (ref: AssetRef) => void;
}

export const useImageGen = create<ImageGenState>((set) => ({
  prompt: "",
  aspect: "9:16",
  refs: [],
  openWith: (prompt) => set({ prompt, refs: [] }),
  setPrompt: (prompt) => set({ prompt }),
  setAspect: (aspect) => set({ aspect }),
  addRef: (ref) => set((s) => ({ refs: addRefOnce(s.refs, ref) })),
  removeRef: (ref) => set((s) => ({ refs: s.refs.filter((r) => !sameRef(r, ref)) })),
}));
