"use client";

import { create } from "zustand";
import { addRefOnce, sameRef, type AssetRef } from "./assetRef";
import type { StockVideo } from "./stock";

// The generate-video panel's state, shared between the stock-video browser
// (which loads a stock clip's saved prompt into it on click) and the always-on
// generate panel that sits beside the browser in the Video tab.

interface VideoGenState {
  prompt: string;
  /** Visual references attached to the next generation (dragged in or picked
   * via @name mentions resolved on send). */
  refs: AssetRef[];
  /** Character mode: the picked talking character. The panel's text is the
   * line they speak, composed with the character's persona on send; null is
   * free-form prompting. */
  character: StockVideo | null;
  /** Load a starting prompt into the panel (a stock clip's saved prompt, or
   * "" for a blank generation). Resets references and leaves character mode. */
  openWith: (prompt: string) => void;
  /** Enter character mode for a stock talking character. */
  openCharacter: (character: StockVideo) => void;
  clearCharacter: () => void;
  setPrompt: (prompt: string) => void;
  addRef: (ref: AssetRef) => void;
  removeRef: (ref: AssetRef) => void;
}

export const useVideoGen = create<VideoGenState>((set) => ({
  prompt: "",
  refs: [],
  character: null,
  openWith: (prompt) => set({ prompt, refs: [], character: null }),
  openCharacter: (character) => set({ character, prompt: "", refs: [] }),
  clearCharacter: () => set({ character: null }),
  setPrompt: (prompt) => set({ prompt }),
  addRef: (ref) => set((s) => ({ refs: addRefOnce(s.refs, ref) })),
  removeRef: (ref) => set((s) => ({ refs: s.refs.filter((r) => !sameRef(r, ref)) })),
}));
