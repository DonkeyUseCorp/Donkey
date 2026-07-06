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

interface LibraryIndex {
  assets: LibraryAsset[];
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

async function register(fileName: string, name: string): Promise<LibraryAsset> {
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
