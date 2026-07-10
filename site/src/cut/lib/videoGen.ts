"use client";

import { create } from "zustand";
import { addRefOnce, sameRef, type AssetRef } from "./assetRef";

// The generate-video panel's state, shared between the stock-video browser
// (which loads a stock clip's saved prompt into it on click) and the always-on
// generate panel that sits beside the browser in the Video tab.

interface VideoGenState {
  prompt: string;
  /** Visual references attached to the next generation (dragged in or picked
   * via @name mentions resolved on send). */
  refs: AssetRef[];
  /** Load a starting prompt into the panel (a stock clip's saved prompt, or
   * "" for a blank generation). Resets any attached references. */
  openWith: (prompt: string) => void;
  setPrompt: (prompt: string) => void;
  addRef: (ref: AssetRef) => void;
  removeRef: (ref: AssetRef) => void;
}

export const useVideoGen = create<VideoGenState>((set) => ({
  prompt: "",
  refs: [],
  openWith: (prompt) => set({ prompt, refs: [] }),
  setPrompt: (prompt) => set({ prompt }),
  addRef: (ref) => set((s) => ({ refs: addRefOnce(s.refs, ref) })),
  removeRef: (ref) => set((s) => ({ refs: s.refs.filter((r) => !sameRef(r, ref)) })),
}));
