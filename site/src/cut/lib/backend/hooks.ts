// React bindings for the backend seam, kept out of ./index so the engine
// binary (which compiles lib/types.ts → ./index) never bundles React.
import { useSyncExternalStore } from "react";

import { cutMode, getBackend, subscribeCutMode } from "./index";
import type { CutCaps, CutMode } from "./types";

export function useCutMode(): CutMode {
  return useSyncExternalStore(subscribeCutMode, cutMode, () => "local" as const);
}

export function useCutCaps(): CutCaps {
  useCutMode();
  return getBackend().caps;
}
