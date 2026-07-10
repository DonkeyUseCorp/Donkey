"use client";

import { apiFetch, apiJson, apiUrl } from "./api";
import { enrichAsset } from "./media";
import { useEditor } from "./store";
import type { LibraryTemplate, MediaAsset, TemplateMedia, TemplateSaveInput } from "./types";
import { mediaUrl } from "./types";

export interface LibrarySource {
  url: string;
  title?: string;
  uploader?: string;
  uploadDate?: string;
}

export interface LibraryAsset {
  id: string;
  fileName: string;
  name: string;
  type: "video" | "audio";
  duration: number;
  width?: number;
  height?: number;
  addedAt: number;
  folderId?: string | null;
  source?: LibrarySource;
}

export interface LibraryFolder {
  id: string;
  name: string;
  createdAt: number;
}

export interface LibraryData {
  assets: LibraryAsset[];
  folders: LibraryFolder[];
  templates: LibraryTemplate[];
}

export const libraryMediaUrl = (fileName: string) =>
  apiUrl(`/api/cut/library/media/${encodeURIComponent(fileName)}`);

export async function fetchLibrary(): Promise<LibraryData> {
  const res = await apiFetch("/api/cut/library");
  if (!res.ok) throw new Error("Could not load the library.");
  return (await res.json()) as LibraryData;
}

export async function importUrlToLibrary(url: string): Promise<LibraryAsset> {
  const res = await apiFetch("/api/cut/library/import-url", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ url }),
  });
  const body = await apiJson<LibraryAsset>(res);
  if (!res.ok) throw new Error(body.error ?? "Could not import that URL.");
  return body;
}

export async function createLibraryFolder(name: string): Promise<LibraryFolder> {
  const res = await apiFetch("/api/cut/library/folders", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name }),
  });
  const body = await apiJson<LibraryFolder>(res);
  if (!res.ok) throw new Error(body.error ?? "Could not create folder.");
  return body;
}

export async function renameLibraryFolder(id: string, name: string): Promise<void> {
  const res = await apiFetch(`/api/cut/library/folders/${id}`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name }),
  });
  if (!res.ok) throw new Error("Could not rename folder.");
}

export async function deleteLibraryFolder(id: string): Promise<void> {
  const res = await apiFetch(`/api/cut/library/folders/${id}`, { method: "DELETE" });
  if (!res.ok) throw new Error("Could not delete folder.");
}

export async function moveLibraryAsset(assetId: string, folderId: string | null): Promise<void> {
  const res = await apiFetch("/api/cut/library/move", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ assetId, folderId }),
  });
  if (!res.ok) throw new Error("Could not move asset.");
}

export async function uploadToLibrary(file: File): Promise<LibraryAsset> {
  const form = new FormData();
  form.append("file", file, file.name);
  const res = await apiFetch("/api/cut/library", { method: "POST", body: form });
  const body = await apiJson<LibraryAsset>(res);
  if (!res.ok) throw new Error(body.error ?? "Upload failed.");
  return body;
}

export async function deleteFromLibrary(id: string) {
  const res = await apiFetch(`/api/cut/library/${id}`, { method: "DELETE" });
  if (!res.ok) throw new Error("Could not delete.");
}

/** Copy a library asset into the open project's media and register it, without
 * placing it on the timeline. Callers choose where it lands. */
export async function importLibraryAsset(
  projectId: string,
  lib: LibraryAsset
): Promise<MediaAsset> {
  const res = await apiFetch("/api/cut/library/use", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ assetId: lib.id, projectId }),
  });
  const body = await apiJson<{ fileName?: string }>(res);
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
  useEditor.getState().addAsset(asset);
  // Generate filmstrip thumbnails / waveform peaks so the clip renders like any
  // other on the timeline (project uploads get this via the editor on add).
  void enrichAsset(asset);
  return asset;
}

/** Copy a library asset into the open project and append it to the timeline. */
export async function addLibraryAssetToProject(
  projectId: string,
  lib: LibraryAsset
): Promise<MediaAsset> {
  const asset = await importLibraryAsset(projectId, lib);
  const s = useEditor.getState();
  if (asset.type === "video") s.addClipFromAsset(asset.id);
  else s.addAudioFromAsset(asset.id);
  return asset;
}

/** Save the current timeline selection as a by-reference template. */
export async function saveTemplate(
  projectId: string,
  input: TemplateSaveInput
): Promise<LibraryTemplate> {
  const res = await apiFetch("/api/cut/library/templates", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ projectId, ...input }),
  });
  const body = await apiJson<LibraryTemplate>(res);
  if (!res.ok) throw new Error(body.error ?? "Could not save the template.");
  return body;
}

export async function deleteTemplate(id: string): Promise<void> {
  const res = await apiFetch(`/api/cut/library/templates/${id}`, { method: "DELETE" });
  if (!res.ok) throw new Error("Could not delete the template.");
}

/** Copy a template's media into the open project and re-materialize its clips,
 * overlays, and captions at the playhead — everything editable, nothing baked. */
export async function addTemplateToProject(
  projectId: string,
  template: LibraryTemplate
): Promise<void> {
  const res = await apiFetch(`/api/cut/library/templates/${template.id}/use`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ projectId }),
  });
  const body = await apiJson<{ media?: TemplateMedia[] }>(res);
  if (!res.ok || !body.media) throw new Error(body.error ?? "Could not add the template.");

  const s = useEditor.getState();
  // Each returned media file (in template.media order) becomes a project asset;
  // the layer/audio media indices resolve against this array.
  const assetIds = body.media.map((m) => {
    const asset: MediaAsset = {
      id: crypto.randomUUID().slice(0, 8),
      fileName: m.fileName,
      name: m.name,
      type: m.type,
      duration: m.duration,
      width: m.width,
      height: m.height,
      url: mediaUrl(projectId, m.fileName),
    };
    s.addAsset(asset);
    return asset.id;
  });
  s.insertTemplate(template, assetIds, useEditor.getState().currentTime);
}

/** Copy a project asset into the shared library for reuse. */
export async function saveAssetToLibrary(projectId: string, asset: MediaAsset) {
  const res = await apiFetch("/api/cut/library/save", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ projectId, fileName: asset.fileName, name: asset.name }),
  });
  const body = await apiJson<LibraryAsset>(res);
  if (!res.ok) throw new Error(body.error ?? "Could not save to library.");
  return body;
}
