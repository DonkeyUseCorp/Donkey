"use client";

import { apiFetch, apiUrl } from "./api";
import { useEditor } from "./store";
import type { MediaAsset } from "./types";
import { mediaUrl } from "./types";

export interface LibraryAsset {
  id: string;
  fileName: string;
  name: string;
  type: "video" | "audio";
  duration: number;
  width?: number;
  height?: number;
  addedAt: number;
}

export const libraryMediaUrl = (fileName: string) =>
  apiUrl(`/api/library/media/${encodeURIComponent(fileName)}`);

export async function fetchLibrary(): Promise<LibraryAsset[]> {
  const res = await apiFetch("/api/library");
  if (!res.ok) throw new Error("Could not load the library.");
  return (await res.json()) as LibraryAsset[];
}

export async function uploadToLibrary(file: File): Promise<LibraryAsset> {
  const form = new FormData();
  form.append("file", file, file.name);
  const res = await apiFetch("/api/library", { method: "POST", body: form });
  const body = (await res.json()) as LibraryAsset & { error?: string };
  if (!res.ok) throw new Error(body.error ?? "Upload failed.");
  return body;
}

export async function deleteFromLibrary(id: string) {
  const res = await apiFetch(`/api/library/${id}`, { method: "DELETE" });
  if (!res.ok) throw new Error("Could not delete.");
}

/** Copy a library asset into the open project and put it on the timeline. */
export async function addLibraryAssetToProject(
  projectId: string,
  lib: LibraryAsset
): Promise<MediaAsset> {
  const res = await apiFetch("/api/library/use", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ assetId: lib.id, projectId }),
  });
  const body = (await res.json()) as { fileName?: string; error?: string };
  if (!res.ok || !body.fileName) throw new Error(body.error ?? "Could not add from library.");

  const asset: MediaAsset = {
    id: crypto.randomUUID().slice(0, 8),
    fileName: body.fileName,
    name: lib.name,
    type: lib.type,
    duration: lib.duration,
    width: lib.width,
    height: lib.height,
    url: mediaUrl(projectId, body.fileName),
  };
  const s = useEditor.getState();
  s.addAsset(asset);
  if (asset.type === "video") s.addClipFromAsset(asset.id);
  else s.addAudioFromAsset(asset.id);
  return asset;
}

/** Copy a project asset into the shared library for reuse. */
export async function saveAssetToLibrary(projectId: string, asset: MediaAsset) {
  const res = await apiFetch("/api/library/save", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ projectId, fileName: asset.fileName, name: asset.name }),
  });
  const body = (await res.json()) as LibraryAsset & { error?: string };
  if (!res.ok) throw new Error(body.error ?? "Could not save to library.");
  return body;
}
