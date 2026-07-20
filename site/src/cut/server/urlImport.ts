import { spawn } from "node:child_process";
import { copyFile, mkdir, mkdtemp, readdir, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { addDownloaded, type LibraryAsset, type LibrarySource } from "./library";
import { assertLocalRuntime } from "./local-only";
import { mediaDir, mediaPath as projectMediaPath, readProject } from "./projects";
import { uniqueName } from "./util";

// Download a media URL (TikTok, YouTube, Instagram, …) with the bundled
// yt-dlp, resolved from the widened PATH (tool-path.ts) exactly like ffmpeg.
// yt-dlp only extracts video/audio, so a photo tweet falls back to fetching
// the image through X's embed endpoint.

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

/** What a finished download hands its consumer: the media files (inside a
 * temp dir the wrapper deletes afterwards — one for yt-dlp's merged output,
 * one per photo for a photo tweet) plus what the extractor knew about them.
 * `text` is the full post text when the URL was a tweet. */
interface Downloaded {
  files: { file: string; title: string }[];
  source: LibrarySource;
  text?: string;
}

/** Run one guarded download and hand the files to `consume` before the temp
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
      return await consume(await download(url.trim(), tmp));
    } finally {
      void rm(tmp, { recursive: true, force: true });
    }
  } finally {
    active--;
  }
}

/** Download a URL into the shared Library (the Library panel's import box).
 * A multi-photo tweet lands as one asset per photo. */
export async function importFromUrl(url: string): Promise<LibraryAsset[]> {
  return withDownload(url, async (dl) => {
    const assets: LibraryAsset[] = [];
    for (const f of dl.files) assets.push(await addDownloaded(f.file, f.title, dl.source));
    return assets;
  });
}

/** Download a URL straight into a project's media folder (the chat's
 * import_url tool). Returns the project file names; the client builds and
 * registers the assets. */
export async function importUrlToProject(
  projectId: string,
  url: string
): Promise<{ files: { fileName: string; title: string }[]; source: LibrarySource; text?: string }> {
  if (!(await readProject(projectId))) throw new Error("Project not found.");
  return withDownload(url, async (dl) => {
    await mkdir(mediaDir(projectId), { recursive: true });
    const files: { fileName: string; title: string }[] = [];
    for (const f of dl.files) {
      const dest = await uniqueName(path.basename(f.file), (n) => projectMediaPath(projectId, n));
      await copyFile(f.file, projectMediaPath(projectId, dest));
      files.push({ fileName: dest, title: f.title });
    }
    return { files, source: dl.source, text: dl.text };
  });
}

/** yt-dlp handles anything with a video/audio stream. A direct image link
 * skips it (yt-dlp rejects plain images), and a tweet it can't pull anything
 * from may still carry photos, so those fall through to the photo fetch; its
 * failure rethrows the yt-dlp error, which names the real cause. */
async function download(url: string, tmp: string): Promise<Downloaded> {
  if (IMAGE_URL_RE.test(url)) return downloadDirectImage(url, tmp);
  try {
    return await downloadMedia(url, tmp);
  } catch (e) {
    const tweetId = TWEET_RE.exec(url)?.[1];
    if (!tweetId) throw e;
    try {
      return await downloadTweetPhotos(tweetId, url, tmp);
    } catch {
      throw e;
    }
  }
}

async function downloadMedia(url: string, tmp: string): Promise<Downloaded> {
  const meta = await runYtDlp(url, tmp);
  // Pick the largest media file left behind (the merged output).
  const names = (await readdir(tmp)).filter((f) => MEDIA_EXT.test(f));
  if (names.length === 0) throw new Error("Nothing downloadable was found at that URL.");
  const sized = await Promise.all(
    names.map(async (n) => ({ n, size: (await stat(path.join(tmp, n))).size }))
  );
  const file = sized.sort((a, b) => b.size - a.size)[0].n;
  return {
    files: [{ file: path.join(tmp, file), title: (meta.title || "Imported clip").slice(0, 120) }],
    source: {
      url: meta.webpage_url || url,
      title: meta.title,
      uploader: meta.uploader,
      uploadDate: meta.upload_date,
    },
  };
}

const IMAGE_URL_RE = /\.(png|jpe?g|webp|gif|avif|bmp)(?:$|\?)/i;

async function downloadDirectImage(url: string, dir: string): Promise<Downloaded> {
  const res = await fetch(url);
  if (!res.ok) throw new Error("Could not download that image.");
  const name = path.basename(new URL(url).pathname) || "image.jpg";
  const file = path.join(dir, name);
  await writeFile(file, Buffer.from(await res.arrayBuffer()));
  return { files: [{ file, title: name.slice(0, 120) }], source: { url } };
}

const TWEET_RE = /^https?:\/\/(?:www\.)?(?:x|twitter)\.com\/[^/]+\/status\/(\d+)/i;

/** Fetch all of a tweet's photos through X's embed endpoint, plus the post
 * text. The endpoint is auth-free but requires the token its embed script
 * derives from the id — same float math here, precision loss included. */
async function downloadTweetPhotos(id: string, url: string, dir: string): Promise<Downloaded> {
  const token = ((Number(id) / 1e15) * Math.PI).toString(36).replace(/(0+|\.)/g, "");
  const res = await fetch(`https://cdn.syndication.twimg.com/tweet-result?id=${id}&token=${token}`);
  if (!res.ok) throw new Error("Could not read the tweet.");
  const tweet = (await res.json()) as {
    text?: string;
    user?: { name?: string; screen_name?: string };
    photos?: { url?: string }[];
  };
  const photoUrls = (tweet.photos ?? []).map((p) => p.url).filter((u): u is string => !!u);
  if (photoUrls.length === 0) throw new Error("No photo was found in this tweet.");
  const handle = tweet.user?.screen_name;
  // The endpoint HTML-escapes the post text; it becomes titles and chat text.
  const text = (tweet.text || "")
    .replace(/&(amp|lt|gt|quot|#39);/g, (_, e) =>
      ({ amp: "&", lt: "<", gt: ">", quot: '"', "#39": "'" })[e as string] ?? ""
    )
    .replace(/\s+/g, " ")
    .trim();
  const baseTitle = (text || `Photo from ${handle ? `@${handle}` : "X"}`).slice(0, 120);
  const files: Downloaded["files"] = [];
  for (const [i, photoUrl] of photoUrls.entries()) {
    // pbs.twimg.com serves the original resolution behind name=orig.
    let img = await fetch(`${photoUrl}${photoUrl.includes("?") ? "&" : "?"}name=orig`);
    if (!img.ok) img = await fetch(photoUrl);
    if (!img.ok) throw new Error("Could not download the tweet's photos.");
    const ext = (
      /\.(png|jpe?g|webp|gif)(?:$|\?)/i.exec(photoUrl)?.[1] ||
      (img.headers.get("content-type")?.includes("png") ? "png" : "jpg")
    ).toLowerCase();
    const file = path.join(dir, `${id}-${i + 1}.${ext}`);
    await writeFile(file, Buffer.from(await img.arrayBuffer()));
    files.push({
      file,
      title: photoUrls.length > 1 ? `${baseTitle} (${i + 1}/${photoUrls.length})` : baseTitle,
    });
  }
  return {
    files,
    source: {
      url,
      title: text || undefined,
      uploader: handle ? `@${handle}` : tweet.user?.name,
    },
    text: text || undefined,
  };
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
