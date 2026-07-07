import { spawn } from "node:child_process";
import { copyFile, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { cutDataRoot } from "./dataDir";
import { assertLocalRuntime } from "./local-only";
import { mediaPath as projectMediaPath, readProject } from "./projects";
import { exists, uniqueName, writeJsonAtomic } from "./util";

/** The shared library: reusable media that lives outside any project. */
export const LIBRARY_ROOT = path.join(cutDataRoot(), "library");
const LIB_MEDIA = path.join(LIBRARY_ROOT, "media");
const INDEX = path.join(LIBRARY_ROOT, "library.json");

/** Where a URL-imported asset came from, kept as notes on the asset. */
export interface LibrarySource {
  url: string;
  title?: string;
  uploader?: string;
  uploadDate?: string; // yt-dlp YYYYMMDD
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

/**
 * A saved timeline selection kept *by reference*: the source media plus the
 * edit that arranges it (trims, layout regions, overlays, captions), never a
 * flattened video. Re-adding it copies the media into the project and
 * re-materializes editable clips. Its media files live privately in the library
 * (not as loose assets), so a template stays whole even if the project it came
 * from is deleted. `layers`/`audio` reference `media` by array index.
 */
export interface TemplateMedia {
  fileName: string; // private copy inside the library media folder
  name: string;
  type: "video" | "audio";
  duration: number;
  width?: number;
  height?: number;
}
export interface TemplateLayer {
  media: number; // index into template.media
  start: number;
  in: number;
  out: number;
  frame?: { x: number; y: number; w: number; h: number };
  fit?: "fit" | "fill";
  muted: boolean;
  speed?: number;
  track: number;
  onBase?: boolean; // re-materializes onto the base track rather than an overlay
}
export interface TemplateAudio {
  media: number;
  start: number;
  in: number;
  out: number;
  volume: number;
  fadeIn?: number;
  fadeOut?: number;
  speed?: number;
}
export interface LibraryTemplate {
  id: string;
  name: string;
  addedAt: number;
  duration: number;
  media: TemplateMedia[];
  layers: TemplateLayer[];
  audio: TemplateAudio[];
  texts: unknown[]; // opaque TextOverlay[] round-tripped for the client
  cues: unknown[]; // opaque SubtitleCue[]
}

interface LibraryIndex {
  assets: LibraryAsset[];
  folders?: LibraryFolder[];
  templates?: LibraryTemplate[];
}

export function libMediaPath(fileName: string) {
  assertLocalRuntime();
  const safe = path.basename(fileName);
  if (!safe || safe.startsWith(".")) throw new Error("Invalid file name.");
  return path.join(LIB_MEDIA, safe);
}

async function readIndex(): Promise<LibraryIndex> {
  assertLocalRuntime();
  let raw: string;
  try {
    raw = await readFile(INDEX, "utf8");
  } catch {
    return { assets: [] };
  }
  try {
    return JSON.parse(raw) as LibraryIndex;
  } catch (err) {
    console.error(`Corrupt library index ${INDEX}:`, err);
  }
  try {
    const idx = JSON.parse(await readFile(`${INDEX}.bak`, "utf8")) as LibraryIndex;
    await writeIndex(idx);
    return idx;
  } catch (err) {
    console.error(`Could not recover ${INDEX} from backup:`, err);
    return { assets: [] };
  }
}

async function writeIndex(idx: LibraryIndex) {
  assertLocalRuntime();
  await mkdir(LIB_MEDIA, { recursive: true });
  await writeJsonAtomic(INDEX, idx);
}

export async function listLibrary(): Promise<LibraryAsset[]> {
  const idx = await readIndex();
  return idx.assets.sort((a, b) => b.addedAt - a.addedAt);
}

const VIDEO_RE = /\.(mp4|mov|m4v|webm|mkv)$/i;
const AUDIO_RE = /\.(mp3|m4a|aac|wav|ogg|flac)$/i;

function ffprobe(args: string[]): Promise<string> {
  return new Promise((resolve, reject) => {
    const p = spawn("ffprobe", ["-v", "error", ...args]);
    const timer = setTimeout(() => p.kill("SIGKILL"), 30_000);
    let out = "";
    p.stdout.on("data", (d) => (out += d));
    p.on("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
    p.on("close", (code) => {
      clearTimeout(timer);
      if (code === 0) resolve(out.trim());
      else reject(new Error("Could not read this media file."));
    });
  });
}

async function probe(filePath: string) {
  const duration = parseFloat(
    await ffprobe(["-show_entries", "format=duration", "-of", "csv=p=0", filePath])
  );
  let width: number | undefined;
  let height: number | undefined;
  if (VIDEO_RE.test(filePath)) {
    const dims = await ffprobe([
      "-select_streams", "v:0",
      "-show_entries", "stream=width,height",
      "-of", "csv=p=0",
      filePath,
    ]).catch(() => "");
    const [w, h] = dims.split(",").map(Number);
    if (w && h) {
      width = w;
      height = h;
    }
  }
  return { duration: Number.isFinite(duration) ? duration : 0, width, height };
}

async function freeName(original: string) {
  const base = path.basename(original).replace(/[^\w.\-() ]+/g, "_").slice(-80);
  return uniqueName(base, libMediaPath);
}

function typeOf(fileName: string): "video" | "audio" | null {
  if (VIDEO_RE.test(fileName)) return "video";
  if (AUDIO_RE.test(fileName)) return "audio";
  return null;
}

export async function register(
  fileName: string,
  name: string,
  source?: LibrarySource
): Promise<LibraryAsset> {
  const type = typeOf(fileName);
  if (!type) throw new Error("Unsupported file type.");
  const meta = await probe(libMediaPath(fileName));
  const asset: LibraryAsset = {
    id: crypto.randomUUID().slice(0, 8),
    fileName,
    name,
    type,
    duration: meta.duration,
    ...(meta.width ? { width: meta.width, height: meta.height } : {}),
    addedAt: Date.now(),
    folderId: null,
    ...(source ? { source } : {}),
  };
  const idx = await readIndex();
  idx.assets.push(asset);
  await writeIndex(idx);
  return asset;
}

/** Upload a file straight into the library. */
export async function addUpload(file: File): Promise<LibraryAsset> {
  if (!typeOf(file.name)) throw new Error("Unsupported file type.");
  await mkdir(LIB_MEDIA, { recursive: true });
  const fileName = await freeName(file.name);
  await writeFile(libMediaPath(fileName), Buffer.from(await file.arrayBuffer()));
  return register(fileName, file.name);
}

/** Copy a project's media file into the library for reuse. */
export async function addFromProject(
  projectId: string,
  fileName: string,
  name: string
): Promise<LibraryAsset> {
  const src = projectMediaPath(projectId, fileName);
  if (!(await exists(src))) throw new Error("Media file not found in project.");
  await mkdir(LIB_MEDIA, { recursive: true });
  const dest = await freeName(fileName);
  await copyFile(src, libMediaPath(dest));
  return register(dest, name || fileName);
}

/** Move a freshly downloaded file into the library and register it. */
export async function addDownloaded(
  srcPath: string,
  name: string,
  source?: LibrarySource
): Promise<LibraryAsset> {
  if (!typeOf(srcPath)) throw new Error("Unsupported file type.");
  await mkdir(LIB_MEDIA, { recursive: true });
  const dest = await freeName(path.basename(srcPath));
  await copyFile(srcPath, libMediaPath(dest));
  return register(dest, name || path.basename(srcPath), source);
}

/** Copy a library asset into a project's media folder. Returns the file name
 * inside the project. */
export async function useInProject(assetId: string, projectId: string): Promise<string> {
  const idx = await readIndex();
  const asset = idx.assets.find((a) => a.id === assetId);
  if (!asset) throw new Error("Library asset not found.");
  if (!(await readProject(projectId))) throw new Error("Project not found.");

  const base = asset.fileName;
  const dest = await uniqueName(base, (n) => projectMediaPath(projectId, n));
  await copyFile(libMediaPath(base), projectMediaPath(projectId, dest));
  return dest;
}

export async function removeAsset(id: string) {
  const idx = await readIndex();
  const asset = idx.assets.find((a) => a.id === id);
  if (!asset) throw new Error("Library asset not found.");
  idx.assets = idx.assets.filter((a) => a.id !== id);
  await writeIndex(idx);
  await rm(libMediaPath(asset.fileName), { force: true });
}

export function getAsset(id: string) {
  return readIndex().then((idx) => idx.assets.find((a) => a.id === id));
}

// --- Folders: a flat set of named groups; assets carry a folderId. ---

export async function listFolders(): Promise<LibraryFolder[]> {
  const idx = await readIndex();
  return (idx.folders ?? []).slice().sort((a, b) => a.createdAt - b.createdAt);
}

export async function createFolder(name: string): Promise<LibraryFolder> {
  const trimmed = name.trim();
  if (!trimmed) throw new Error("Folder name required.");
  const folder: LibraryFolder = {
    id: crypto.randomUUID().slice(0, 8),
    name: trimmed.slice(0, 80),
    createdAt: Date.now(),
  };
  const idx = await readIndex();
  idx.folders = [...(idx.folders ?? []), folder];
  await writeIndex(idx);
  return folder;
}

export async function renameFolder(id: string, name: string): Promise<LibraryFolder> {
  const trimmed = name.trim();
  if (!trimmed) throw new Error("Folder name required.");
  const idx = await readIndex();
  const folder = (idx.folders ?? []).find((f) => f.id === id);
  if (!folder) throw new Error("Folder not found.");
  folder.name = trimmed.slice(0, 80);
  await writeIndex(idx);
  return folder;
}

export async function deleteFolder(id: string) {
  const idx = await readIndex();
  idx.folders = (idx.folders ?? []).filter((f) => f.id !== id);
  // Assets in the folder fall back to ungrouped rather than vanishing.
  for (const a of idx.assets) if (a.folderId === id) a.folderId = null;
  await writeIndex(idx);
}

export async function moveAsset(assetId: string, folderId: string | null) {
  const idx = await readIndex();
  const asset = idx.assets.find((a) => a.id === assetId);
  if (!asset) throw new Error("Library asset not found.");
  if (folderId && !(idx.folders ?? []).some((f) => f.id === folderId)) {
    throw new Error("Folder not found.");
  }
  asset.folderId = folderId;
  await writeIndex(idx);
}

// --- Templates: reusable selections saved by reference (see LibraryTemplate). ---

/** What the client sends to save a selection: source media (project files) plus
 * the edit that arranges them, referencing media by array index. */
export interface TemplateInput {
  name: string;
  duration: number;
  media: { fileName: string; name: string; type: "video" | "audio"; duration: number; width?: number; height?: number }[];
  layers: TemplateLayer[];
  audio: TemplateAudio[];
  texts: unknown[];
  cues: unknown[];
}

export async function listTemplates(): Promise<LibraryTemplate[]> {
  const idx = await readIndex();
  return (idx.templates ?? []).slice().sort((a, b) => b.addedAt - a.addedAt);
}

/** Save a selection as a template: copy each source into the library privately
 * and store the edit that references it. */
export async function saveTemplate(projectId: string, input: TemplateInput): Promise<LibraryTemplate> {
  if (!(await readProject(projectId))) throw new Error("Project not found.");
  if (!input.media?.length && !input.texts?.length && !input.cues?.length) {
    throw new Error("Nothing to save.");
  }
  await mkdir(LIB_MEDIA, { recursive: true });
  const media: TemplateMedia[] = [];
  for (const m of input.media) {
    const src = projectMediaPath(projectId, m.fileName);
    if (!(await exists(src))) throw new Error("Media file not found in project.");
    const dest = await freeName(m.fileName);
    await copyFile(src, libMediaPath(dest));
    media.push({ fileName: dest, name: m.name, type: m.type, duration: m.duration, width: m.width, height: m.height });
  }
  const template: LibraryTemplate = {
    id: crypto.randomUUID().slice(0, 8),
    name: (input.name || "Template").trim().slice(0, 80),
    addedAt: Date.now(),
    duration: input.duration,
    media,
    layers: input.layers ?? [],
    audio: input.audio ?? [],
    texts: input.texts ?? [],
    cues: input.cues ?? [],
  };
  const idx = await readIndex();
  idx.templates = [...(idx.templates ?? []), template];
  await writeIndex(idx);
  return template;
}

/** Materialize a template into a project: copy its media in and hand the client
 * the project file names (in template media order) plus the stored edit. */
export async function useTemplate(templateId: string, projectId: string) {
  if (!(await readProject(projectId))) throw new Error("Project not found.");
  const idx = await readIndex();
  const template = (idx.templates ?? []).find((x) => x.id === templateId);
  if (!template) throw new Error("Template not found.");
  const media: TemplateMedia[] = [];
  for (const m of template.media) {
    const dest = await uniqueName(m.fileName, (n) => projectMediaPath(projectId, n));
    await copyFile(libMediaPath(m.fileName), projectMediaPath(projectId, dest));
    media.push({ ...m, fileName: dest });
  }
  return { template, media };
}

export async function deleteTemplate(id: string) {
  const idx = await readIndex();
  const template = (idx.templates ?? []).find((x) => x.id === id);
  idx.templates = (idx.templates ?? []).filter((x) => x.id !== id);
  await writeIndex(idx);
  // The media copies are private to this template, so removing them is safe.
  for (const m of template?.media ?? []) await rm(libMediaPath(m.fileName), { force: true });
}
