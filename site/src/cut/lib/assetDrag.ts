"use client";

import type React from "react";
import { clearRefDrag, refFromAsset, refFromLibrary, setRefDragData } from "./assetRef";
import type { LibraryAsset } from "./library";
import { useEditor } from "./store";

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
  // Every media drag also carries the unified asset ref, so reference drop
  // zones (AI chat, the image/video creators) accept it without knowing the
  // source surface.
  const asset = useEditor.getState().assets.find((a) => a.id === assetId);
  if (asset) setRefDragData(e, refFromAsset(asset));
}

/** The asset id currently being dragged, readable during `dragover`. */
export function draggingAssetId(): string | null {
  return inFlightAssetId;
}

/** A library asset dragged from the library panel. Unlike a project asset it is
 * not in the project yet, so it carries its own MIME and a minimal shape the
 * timeline uses to size the drop preview before the copy-into-project happens. */
export const LIBRARY_MIME = "application/x-cut-library";

let inFlightLibrary: LibraryAsset | null = null;

export function setLibraryDragData(e: React.DragEvent, asset: LibraryAsset) {
  e.dataTransfer.setData(LIBRARY_MIME, asset.id);
  e.dataTransfer.effectAllowed = "copy";
  inFlightLibrary = asset;
  setRefDragData(e, refFromLibrary(asset));
}

export function draggingLibrary(): LibraryAsset | null {
  return inFlightLibrary;
}

export function hasLibraryDrag(e: React.DragEvent | DragEvent): boolean {
  const dt = "dataTransfer" in e ? e.dataTransfer : null;
  return !!dt && Array.from(dt.types).includes(LIBRARY_MIME);
}

export function draggedLibraryId(e: React.DragEvent | DragEvent): string | null {
  const dt = "dataTransfer" in e ? e.dataTransfer : null;
  if (!dt || !Array.from(dt.types).includes(LIBRARY_MIME)) return null;
  return dt.getData(LIBRARY_MIME) || null;
}

/** Clear the in-flight ids; call on `dragend` and after a drop. */
export function clearAssetDrag() {
  inFlightAssetId = null;
  inFlightLibrary = null;
  clearRefDrag();
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
