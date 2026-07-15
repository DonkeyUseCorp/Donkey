"use client";

import { create } from "zustand";
import { addRefOnce, sameRef, type AssetRef } from "./assetRef";
import type { StockVideo } from "./stock";

// The generate-video panel's state, shared between the stock-video browser
// (which loads a stock clip's saved prompt into it on click) and the always-on
// generate panel that sits beside the browser in the Video tab.

/** The shape the next generated clip is composed in — Veo renders landscape
 * and portrait. */
export type VideoAspect = "16:9" | "9:16";

export const VIDEO_ASPECT_LABEL: Record<VideoAspect, string> = {
  "16:9": "Landscape (16:9)",
  "9:16": "Portrait (9:16)",
};

/** Output detail the next clip renders at. */
export type VideoResolution = "720p" | "1080p";

/** A selectable video model: the tier the backend resolves to a concrete
 * model id (gemini-models.ts) plus the knobs that model supports. The
 * generate panel renders its duration/aspect/resolution controls from the
 * selected entry and clamps stored picks to it, so adding a model here is the
 * whole client-side change. */
export interface VideoModelOption {
  tier: "fast" | "high";
  /** Segment label ("Fast") and the model name shown beside it. */
  word: string;
  model: string;
  durations: number[];
  aspects: VideoAspect[];
  resolutions: VideoResolution[];
}

export const VIDEO_MODELS: VideoModelOption[] = [
  {
    tier: "fast",
    word: "Fast",
    model: "Veo 3.1 Fast",
    durations: [4, 6, 8],
    aspects: ["16:9", "9:16"],
    resolutions: ["720p", "1080p"],
  },
  {
    tier: "high",
    word: "Best",
    model: "Veo 3.1",
    durations: [4, 6, 8],
    aspects: ["16:9", "9:16"],
    resolutions: ["720p", "1080p"],
  },
];

/** The registry entry for a tier — the single source of truth for what that
 * model supports. Any code that generates video (the panel, the scene pipeline)
 * reads its constraints from here, so swapping models is one edit in this file. */
export function videoModel(tier: "fast" | "high"): VideoModelOption {
  return VIDEO_MODELS.find((m) => m.tier === tier) ?? VIDEO_MODELS[0];
}

/** Snap a desired clip length to one the model actually renders: the shortest
 * supported duration that still covers `seconds` (the caller trims down to the
 * exact need), or the model's longest. Video models render only a fixed set of
 * lengths and reject anything else, so a caller must never pass a raw duration. */
export function supportedVideoDuration(tier: "fast" | "high", seconds: number): number {
  const durations = [...videoModel(tier).durations].sort((a, b) => a - b);
  return durations.find((d) => d >= seconds) ?? durations[durations.length - 1];
}

interface VideoGenState {
  prompt: string;
  /** The shape the next generation is composed in. */
  aspect: VideoAspect;
  /** The output detail the next generation renders at. */
  resolution: VideoResolution;
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
  setAspect: (aspect: VideoAspect) => void;
  setResolution: (resolution: VideoResolution) => void;
  addRef: (ref: AssetRef) => void;
  removeRef: (ref: AssetRef) => void;
}

export const useVideoGen = create<VideoGenState>((set) => ({
  prompt: "",
  aspect: "16:9",
  resolution: "720p",
  refs: [],
  character: null,
  openWith: (prompt) => set({ prompt, refs: [], character: null }),
  openCharacter: (character) => set({ character, prompt: "", refs: [] }),
  clearCharacter: () => set({ character: null }),
  setPrompt: (prompt) => set({ prompt }),
  setAspect: (aspect) => set({ aspect }),
  setResolution: (resolution) => set({ resolution }),
  addRef: (ref) => set((s) => ({ refs: addRefOnce(s.refs, ref) })),
  removeRef: (ref) => set((s) => ({ refs: s.refs.filter((r) => !sameRef(r, ref)) })),
}));
