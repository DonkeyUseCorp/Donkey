import { spawn } from "node:child_process";
import { copyFile, mkdir, mkdtemp, readdir, rm, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { addDownloaded, type LibraryAsset, type LibrarySource } from "./library";
import { assertLocalRuntime } from "./local-only";
import { mediaDir, mediaPath as projectMediaPath, readProject } from "./projects";
import { uniqueName } from "./util";

// Download a media URL (TikTok, YouTube, Instagram, …) with the bundled
// yt-dlp. The engine finds yt-dlp on its widened PATH exactly like ffmpeg.

const MEDIA_EXT = /\.(mp4|mov|m4v|webm|mkv|mp3|m4a|aac|wav|ogg|flac)$/i;

// A small ceiling so a burst of pastes can't spawn unbounded downloads.
const MAX_ACTIVE = 2;
let active = 0;

interface YtMeta {
  title?: string;
  uploader?: string;
  upload_date?: string;
  webpage_url?: string;
}

/** What a finished download hands its consumer: the merged media file (inside
 * a temp dir the wrapper deletes afterwards) plus what yt-dlp knew about it. */
interface Downloaded {
  file: string;
  title: string;
  source: LibrarySource;
}

/** Run one guarded download and hand the file to `consume` before the temp
 * dir is deleted. The active slot spans the whole operation; mkdtemp runs
 * inside the try so a failure there still releases the slot (else a rejection
 * would leak it and, after MAX_ACTIVE failures, brick URL import until
 * restart). */
async function withDownload<T>(url: string, consume: (dl: Downloaded) => Promise<T>): Promise<T> {
  assertLocalRuntime();
  if (!/^https?:\/\//i.test(url.trim())) throw new Error("Enter a valid http(s) URL.");
  if (active >= MAX_ACTIVE) {
    throw new Error("Too many downloads in progress. Try again in a moment.");
  }
  active++;
  try {
    const tmp = await mkdtemp(path.join(os.tmpdir(), "cut-dl-"));
    try {
      const meta = await runYtDlp(url.trim(), tmp);
      // Pick the largest media file left behind (the merged output).
      const names = (await readdir(tmp)).filter((f) => MEDIA_EXT.test(f));
      if (names.length === 0) throw new Error("Nothing downloadable was found at that URL.");
      const sized = await Promise.all(
        names.map(async (n) => ({ n, size: (await stat(path.join(tmp, n))).size }))
      );
      const file = sized.sort((a, b) => b.size - a.size)[0].n;
      return await consume({
        file: path.join(tmp, file),
        title: (meta.title || "Imported clip").slice(0, 120),
        source: {
          url: meta.webpage_url || url.trim(),
          title: meta.title,
          uploader: meta.uploader,
          uploadDate: meta.upload_date,
        },
      });
    } finally {
      void rm(tmp, { recursive: true, force: true });
    }
  } finally {
    active--;
  }
}

/** Download a URL into the shared Library (the Library panel's import box). */
export async function importFromUrl(url: string): Promise<LibraryAsset> {
  return withDownload(url, (dl) => addDownloaded(dl.file, dl.title, dl.source));
}

/** Download a URL straight into a project's media folder (the chat's
 * import_url tool). Returns the project file name; the client builds and
 * registers the asset. */
export async function importUrlToProject(
  projectId: string,
  url: string
): Promise<{ fileName: string; title: string; source: LibrarySource }> {
  if (!(await readProject(projectId))) throw new Error("Project not found.");
  return withDownload(url, async (dl) => {
    await mkdir(mediaDir(projectId), { recursive: true });
    const dest = await uniqueName(path.basename(dl.file), (n) => projectMediaPath(projectId, n));
    await copyFile(dl.file, projectMediaPath(projectId, dest));
    return { fileName: dest, title: dl.title, source: dl.source };
  });
}

function runYtDlp(url: string, dir: string): Promise<YtMeta> {
  return new Promise((resolve, reject) => {
    const p = spawn("yt-dlp", [
      "--no-playlist",
      "--no-progress",
      "-f", "mp4/bestvideo*+bestaudio/best",
      "--merge-output-format", "mp4",
      "-o", path.join(dir, "%(id)s.%(ext)s"),
      "--print-json",
      url,
    ]);
    const timer = setTimeout(() => {
      p.kill("SIGKILL");
      reject(new Error("Download timed out."));
    }, 300_000);
    timer.unref();
    let out = "";
    let err = "";
    p.stdout.on("data", (d) => (out += d.toString()));
    p.stderr.on("data", (d) => (err = (err + d.toString()).slice(-2000)));
    p.on("error", (e) => {
      clearTimeout(timer);
      reject(
        e.message.includes("ENOENT")
          ? new Error("yt-dlp is not available in this build.")
          : e
      );
    });
    p.on("close", (code) => {
      clearTimeout(timer);
      if (code !== 0) {
        reject(new Error(err.split("\n").filter(Boolean).slice(-1)[0] || "Download failed."));
        return;
      }
      // --print-json emits the info dict as JSON; take the last JSON line.
      const line = out.trim().split("\n").reverse().find((l) => l.trimStart().startsWith("{"));
      try {
        resolve(line ? (JSON.parse(line) as YtMeta) : {});
      } catch {
        resolve({});
      }
    });
  });
}
