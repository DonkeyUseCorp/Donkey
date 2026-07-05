"use client";

import type React from "react";

/** Internal HTML5 drag payload for project media assets. The custom MIME
 * keeps these drags invisible to the window-level OS-file import overlay,
 * which only reacts to `Files`. */
export const ASSET_MIME = "application/x-cut-asset";

/** The asset id of the in-flight drag. `getData` is drop-only, so a drop
 * target that needs the id during `dragover` (e.g. to size an insertion
 * preview) reads it here instead. */
let inFlightAssetId: string | null = null;

export function setAssetDragData(e: React.DragEvent, assetId: string) {
  e.dataTransfer.setData(ASSET_MIME, assetId);
  e.dataTransfer.effectAllowed = "copy";
  inFlightAssetId = assetId;
}

/** The asset id currently being dragged, readable during `dragover`. */
export function draggingAssetId(): string | null {
  return inFlightAssetId;
}

/** Clear the in-flight id; call on `dragend` and after a drop. */
export function clearAssetDrag() {
  inFlightAssetId = null;
}

export function draggedAssetId(e: React.DragEvent | DragEvent): string | null {
  const dt = "dataTransfer" in e ? e.dataTransfer : null;
  if (!dt || !Array.from(dt.types).includes(ASSET_MIME)) return null;
  return dt.getData(ASSET_MIME) || null;
}

/** True while dragging (getData is only readable on drop). */
export function hasAssetDrag(e: React.DragEvent | DragEvent): boolean {
  const dt = "dataTransfer" in e ? e.dataTransfer : null;
  return !!dt && Array.from(dt.types).includes(ASSET_MIME);
}
