import { spawn } from "node:child_process";
import { readdir, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import type { LibrarySource } from "./library";

// Download a media URL (TikTok, YouTube, Instagram, …) with yt-dlp, resolved
// from PATH. yt-dlp only extracts video/audio, so a photo tweet falls back to
// fetching the image through X's embed endpoint. Shared by the local engine's
// import routes (urlImport.ts) and the cloud render worker's import_url jobs.

const MEDIA_EXT = /\.(mp4|mov|m4v|webm|mkv|mp3|m4a|aac|wav|ogg|flac)$/i;

interface YtMeta {
  title?: string;
  description?: string;
  uploader?: string;
  upload_date?: string;
  webpage_url?: string;
}

/** What a finished download hands its consumer: the media files (inside a
 * temp dir the wrapper deletes afterwards — one for yt-dlp's merged output,
 * one per photo for a photo tweet) plus what the extractor knew about them.
 * `text` is the source's own words — a tweet's body, or a video's title and
 * description — shown in the chat beside the media it came with. */
export interface Downloaded {
  files: { file: string; title: string }[];
  source: LibrarySource;
  text?: string;
}

// A video's own words for the chat: its title and description joined, capped so
// a long YouTube description (link dumps, chapter lists) can't flood the chat.
// TikTok/Instagram often repeat the caption as both fields, so drop a
// description that just restates the title.
const MAX_SOURCE_TEXT = 2000;
function sourceTextFromMeta(meta: YtMeta): string | undefined {
  const title = (meta.title || "").trim();
  const desc = (meta.description || "").trim();
  const body =
    desc && desc !== title && !desc.startsWith(title)
      ? title
        ? `${title}\n\n${desc}`
        : desc
      : title || desc;
  const text = body.trim();
  if (!text) return undefined;
  return text.length > MAX_SOURCE_TEXT ? `${text.slice(0, MAX_SOURCE_TEXT).trimEnd()}…` : text;
}

/** yt-dlp handles anything with a video/audio stream. A direct image link
 * skips it (yt-dlp rejects plain images), and a tweet it can't pull anything
 * from may still carry photos, so those fall through to the photo fetch; its
 * failure rethrows the yt-dlp error, which names the real cause. */
export async function download(url: string, tmp: string): Promise<Downloaded> {
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
    text: sourceTextFromMeta(meta),
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
