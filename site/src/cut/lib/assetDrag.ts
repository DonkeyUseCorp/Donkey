"use client";

import type React from "react";

/** Internal HTML5 drag payload for project media assets. The custom MIME
 * keeps these drags invisible to the window-level OS-file import overlay,
 * which only reacts to `Files`. */
export const ASSET_MIME = "application/x-cut-asset";

export function setAssetDragData(e: React.DragEvent, assetId: string) {
  e.dataTransfer.setData(ASSET_MIME, assetId);
  e.dataTransfer.effectAllowed = "copy";
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
