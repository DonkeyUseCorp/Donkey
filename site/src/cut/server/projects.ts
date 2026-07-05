import { mkdir, readdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import type { ProjectDoc, ProjectSummary } from "@/cut/lib/types";
import { assertLocalRuntime } from "./local-only";
import { exists, uniqueName } from "./util";

/** All projects live here; each project is one folder holding project.json,
 * its raw media files, and its exports. */
export const PROJECTS_ROOT = path.join(process.cwd(), "projects");

const ID_RE = /^[a-z0-9][a-z0-9-]{2,40}$/;

export function projectDir(id: string) {
  assertLocalRuntime();
  if (!ID_RE.test(id)) throw new Error("Invalid project id.");
  return path.join(PROJECTS_ROOT, id);
}

export const mediaDir = (id: string) => path.join(projectDir(id), "media");
export const exportsDir = (id: string) => path.join(projectDir(id), "exports");

export function mediaPath(id: string, fileName: string) {
  const safe = path.basename(fileName);
  if (!safe || safe.startsWith(".")) throw new Error("Invalid file name.");
  return path.join(mediaDir(id), safe);
}

export function exportPath(id: string, fileName: string) {
  const safe = path.basename(fileName);
  if (!safe || safe.startsWith(".")) throw new Error("Invalid file name.");
  return path.join(exportsDir(id), safe);
}

/** Rendered exports in the project folder, newest first. */
export async function listExports(id: string) {
  const dir = exportsDir(id);
  const names = await readdir(dir).catch(() => [] as string[]);
  const items = await Promise.all(
    names
      .filter((n) => n.endsWith(".mp4"))
      .map(async (n) => {
        const info = await stat(path.join(dir, n)).catch(() => null);
        return info?.isFile() && info.size > 0
          ? { file: n, size: info.size, mtime: info.mtimeMs }
          : null;
      })
  );
  return items
    .filter((x): x is { file: string; size: number; mtime: number } => x !== null)
    .sort((a, b) => b.mtime - a.mtime);
}

const docPath = (id: string) => path.join(projectDir(id), "project.json");

export async function readProject(id: string): Promise<ProjectDoc | null> {
  try {
    return JSON.parse(await readFile(docPath(id), "utf8")) as ProjectDoc;
  } catch {
    return null;
  }
}

export async function writeProject(id: string, doc: ProjectDoc) {
  doc.updatedAt = Date.now();
  await writeFile(docPath(id), JSON.stringify(doc, null, 2));
}

export async function createProject(name: string): Promise<ProjectSummary> {
  const id = crypto.randomUUID().slice(0, 10);
  await mkdir(mediaDir(id), { recursive: true });
  await mkdir(exportsDir(id), { recursive: true });
  const now = Date.now();
  const doc: ProjectDoc = {
    version: 1,
    name: name.trim() || "Untitled",
    createdAt: now,
    updatedAt: now,
    assets: [],
    clips: [],
    audioClips: [],
    overlays: [],
  };
  await writeFile(docPath(id), JSON.stringify(doc, null, 2));
  return summarize(id, doc);
}

export async function deleteProject(id: string) {
  const dir = projectDir(id);
  if (!(await exists(docPath(id)))) throw new Error("Project not found.");
  await rm(dir, { recursive: true, force: true });
}

function summarize(id: string, doc: ProjectDoc): ProjectSummary {
  const duration = doc.clips.reduce((sum, c) => sum + Math.max(0, c.out - c.in), 0);
  // Preview: the first clip's source video, else any video asset.
  const firstClipAsset = doc.clips.length
    ? doc.assets.find((a) => a.id === doc.clips[0].assetId)
    : undefined;
  const previewAsset =
    firstClipAsset ?? doc.assets.find((a) => a.type === "video");
  return {
    id,
    name: doc.name,
    createdAt: doc.createdAt,
    updatedAt: doc.updatedAt,
    duration,
    clipCount: doc.clips.length,
    assetCount: doc.assets.length,
    previewFile: previewAsset?.fileName,
  };
}

export async function listProjects(): Promise<ProjectSummary[]> {
  assertLocalRuntime();
  await mkdir(PROJECTS_ROOT, { recursive: true });
  const entries = await readdir(PROJECTS_ROOT, { withFileTypes: true });
  const names = entries
    .filter((e) => e.isDirectory() && ID_RE.test(e.name))
    .map((e) => e.name);
  // Read every project.json concurrently — listing latency shouldn't grow
  // linearly with the number of projects.
  const docs = await Promise.all(names.map((n) => readProject(n)));
  return names
    .map((n, i) => (docs[i] ? summarize(n, docs[i]!) : null))
    .filter((x): x is ProjectSummary => x !== null)
    .sort((a, b) => b.updatedAt - a.updatedAt);
}

/** Store an uploaded media file in the project folder, deduping the name. */
export async function saveMedia(id: string, file: File): Promise<string> {
  await mkdir(mediaDir(id), { recursive: true });
  const base = path
    .basename(file.name)
    .replace(/[^\w.\-() ]+/g, "_")
    .slice(-80);
  const fileName = await uniqueName(base, (n) => mediaPath(id, n));
  await writeFile(mediaPath(id, fileName), Buffer.from(await file.arrayBuffer()));
  return fileName;
}
