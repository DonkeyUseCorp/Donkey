"use client";

import { create } from "zustand";
import { addRefOnce, sameRef, type AssetRef } from "./assetRef";

// The generate-image flyover's state, shared between the stock browser (left
// panel, which opens it with a stock image's saved prompt) and the flyover
// itself (mounted over the preview canvas in the editor).

interface ImageGenState {
  open: boolean;
  prompt: string;
  /** Visual references attached to the next generation (dragged in or picked
   * via @name mentions resolved on send). */
  refs: AssetRef[];
  /** Open the flyover with a starting prompt (a stock image's saved prompt,
   * or "" for a blank generation). Resets any attached references. */
  openWith: (prompt: string) => void;
  setPrompt: (prompt: string) => void;
  addRef: (ref: AssetRef) => void;
  removeRef: (ref: AssetRef) => void;
  close: () => void;
}

export const useImageGen = create<ImageGenState>((set) => ({
  open: false,
  prompt: "",
  refs: [],
  openWith: (prompt) => set({ open: true, prompt, refs: [] }),
  setPrompt: (prompt) => set({ prompt }),
  addRef: (ref) => set((s) => ({ refs: addRefOnce(s.refs, ref) })),
  removeRef: (ref) => set((s) => ({ refs: s.refs.filter((r) => !sameRef(r, ref)) })),
  close: () => set({ open: false }),
}));
