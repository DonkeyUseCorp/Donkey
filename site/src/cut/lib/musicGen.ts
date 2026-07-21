"use client";

import { create } from "zustand";

// The Music generator's prompt and vocals toggle live in a store (not local
// component state) so the sample library beside it can load a sample's prompt
// in for remixing — the same way the stock browsers seed the image/video panels.

interface MusicGenState {
  prompt: string;
  /** Whether to render a vocal-free bed (true) or let the model sing (false). */
  instrumental: boolean;
  setPrompt: (prompt: string) => void;
  setInstrumental: (instrumental: boolean) => void;
  /** Seed the generator from a sample: its prompt, and whether it was
   * instrumental so the toggle matches, ready for the user to tweak and render. */
  load: (opts: { prompt: string; instrumental: boolean }) => void;
}

export const useMusicGen = create<MusicGenState>((set) => ({
  prompt: "",
  instrumental: true,
  setPrompt: (prompt) => set({ prompt }),
  setInstrumental: (instrumental) => set({ instrumental }),
  load: ({ prompt, instrumental }) => set({ prompt, instrumental }),
}));
