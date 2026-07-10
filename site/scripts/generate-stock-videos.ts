// Generates the bundled Cut stock-video catalog with the same Veo tier the app
// uses (veo fast), then writes the typed manifest the editor imports.
// Idempotent: items whose file already exists are skipped, so re-running fills
// gaps or picks up new catalog entries only.
//
//   cd site && ./node_modules/.bin/bun scripts/generate-stock-videos.ts
//
// Needs GOOGLE_APPLICATION_CREDENTIALS_JSON (bun auto-loads site/.env) and
// ffmpeg on PATH for the poster thumbs. Each clip renders at 720p, lands as an
// mp4 under public/cut-stock-video, and gets a first-frame WebP thumb the
// browse grid uses.
//
// After generation, every clip is tagged: a vision pass looks at the poster
// frame and extracts the searchable keywords (objects, animals, setting) the
// editor's search box matches. Tags already in the manifest are reused, so
// re-running only tags new or untagged clips.

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { GoogleGenAI } from "@google/genai";
import { JWT } from "google-auth-library";
import sharp from "sharp";

import type { StockCategory, StockVideoAspect } from "../src/cut/lib/stock";

interface CatalogItem {
  id: string;
  category: StockCategory;
  aspect: StockVideoAspect;
  /** Rendered length; Veo takes 4, 6, or 8 seconds. */
  seconds: 4 | 6 | 8;
  prompt: string;
}

const MODEL = process.env.GEMINI_VIDEO_MODEL?.trim() || "veo-3.1-fast-generate-001";
const TAG_MODEL = "gemini-2.5-flash";
const OUT_DIR = path.join(import.meta.dirname, "..", "public", "cut-stock-video");
const MANIFEST = path.join(import.meta.dirname, "..", "src", "cut", "lib", "stockVideoManifest.ts");
// Veo renders take minutes each and quotas are tight; keep the fan-out small.
const CONCURRENCY = 2;
const POLL_MS = 10_000;
/** Longest thumb edge — the browse grid renders tiles well under this. */
const THUMB_EDGE = 512;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

const clip = (subject: string) =>
  `Cinematic stock footage: ${subject} Smooth, steady camera motion, natural lighting, realistic color grading. No text, no watermarks, no logos.`;

const animeClip = (subject: string) =>
  `High-quality anime animation: ${subject} Clean line art, vibrant cel shading, detailed background, smooth motion. No text, no watermarks.`;

const CATALOG: CatalogItem[] = [
  // Business
  { id: "business-team-walkthrough", category: "Business", aspect: "16:9", seconds: 6, prompt: clip("a slow tracking shot following a small team walking and talking through a bright modern office, glass walls and plants passing by.") },
  { id: "business-typing-macro", category: "Business", aspect: "16:9", seconds: 6, prompt: clip("a close-up of hands typing on a laptop at a tidy desk, soft window light, shallow depth of field.") },

  // Nature
  { id: "nature-coast-aerial", category: "Nature", aspect: "16:9", seconds: 6, prompt: clip("a drone shot rising over a foggy coastline at sunrise, waves rolling onto dark sand far below.") },
  { id: "nature-forest-rays", category: "Nature", aspect: "9:16", seconds: 6, prompt: clip("sunbeams drifting through tall pines as morning fog moves slowly between the trunks, camera gliding forward at ground level.") },

  // Travel
  { id: "travel-market-walk", category: "Travel", aspect: "16:9", seconds: 6, prompt: clip("a first-person walk through a lively evening street market, lanterns glowing, vendors and steam from food stalls on both sides.") },
  { id: "travel-beach-stroll", category: "Travel", aspect: "9:16", seconds: 6, prompt: clip("a traveler walking barefoot along the waterline of a white-sand beach at golden hour, gentle waves washing over their footprints.") },

  // City
  { id: "city-night-traffic", category: "City", aspect: "16:9", seconds: 6, prompt: clip("an elevated view of city traffic at night, headlight streams and neon reflections on wet asphalt.") },
  { id: "city-crosswalk-rush", category: "City", aspect: "16:9", seconds: 6, prompt: clip("a busy scramble crosswalk from a high angle, crowds crossing in every direction as the light changes.") },

  // Technology
  { id: "tech-code-glow", category: "Technology", aspect: "16:9", seconds: 6, prompt: clip("a slow push-in on a developer working at a dual-monitor setup in a dim room, screen glow on their face, code scrolling.") },
  { id: "tech-robot-assembly", category: "Technology", aspect: "16:9", seconds: 6, prompt: clip("an industrial robot arm assembling components on a clean production line, precise repeated motion, cool white lighting.") },

  // Anime
  { id: "anime-rain-walk", category: "Anime", aspect: "9:16", seconds: 6, prompt: animeClip("a figure with a glowing umbrella walking toward the viewer down a rain-slicked neon city street at night, puddles rippling.") },
  { id: "anime-cloud-drift", category: "Anime", aspect: "16:9", seconds: 6, prompt: animeClip("towering summer clouds drifting over a green hillside town by the sea, cherry blossom petals carried on the wind.") },

  // Animal
  { id: "animal-dog-sprint", category: "Animal", aspect: "16:9", seconds: 6, prompt: clip("a golden retriever sprinting along a beach at sunset in slow motion, sand kicking up, ears flying.") },
  { id: "animal-flock-sky", category: "Animal", aspect: "16:9", seconds: 6, prompt: clip("a flock of birds wheeling across a pastel dusk sky over still water, reflections mirroring their turns.") },

  // Food & Drink
  { id: "food-coffee-pour", category: "Food & Drink", aspect: "16:9", seconds: 6, prompt: clip("a slow-motion pour of steamed milk into espresso forming latte art, on a marble counter, steam curling upward.") },
  { id: "food-pan-sizzle", category: "Food & Drink", aspect: "16:9", seconds: 6, prompt: clip("vegetables tossed in a sizzling wok over a high flame, embers and steam rising, close-up from the side.") },
];

function makeClient(): { client: GoogleGenAI; authClient: JWT; project: string } {
  const raw = process.env.GOOGLE_APPLICATION_CREDENTIALS_JSON?.trim();
  if (!raw) throw new Error("GOOGLE_APPLICATION_CREDENTIALS_JSON is not set (run from site/ so bun loads .env).");
  const creds = JSON.parse(raw) as { project_id?: string; client_email?: string; private_key?: string; private_key_id?: string };
  if (!creds.project_id || !creds.client_email || !creds.private_key) {
    throw new Error("Service account JSON is missing project_id/client_email/private_key.");
  }
  const authClient = new JWT({
    email: creds.client_email,
    key: creds.private_key,
    keyId: creds.private_key_id,
    scopes: ["https://www.googleapis.com/auth/cloud-platform"],
  });
  const client = new GoogleGenAI({
    vertexai: true,
    location: "global",
    project: creds.project_id,
    googleAuthOptions: { authClient },
  });
  return { client, authClient, project: creds.project_id };
}

/** Renders one clip and resolves to its mp4 bytes — polls the long-running
 * operation, then reads inline bytes or downloads the signed URI. */
async function generateOne(client: GoogleGenAI, authClient: JWT, item: CatalogItem): Promise<Buffer> {
  let op = await client.models.generateVideos({
    model: MODEL,
    prompt: item.prompt,
    config: {
      aspectRatio: item.aspect,
      durationSeconds: item.seconds,
      resolution: "720p",
      generateAudio: true,
    },
  });
  while (!op.done) {
    await sleep(POLL_MS);
    op = await client.operations.getVideosOperation({ operation: op });
  }
  if (op.error) throw new Error(String(op.error.message ?? "video generation failed"));
  const video = op.response?.generatedVideos?.[0]?.video;
  if (video?.videoBytes) return Buffer.from(video.videoBytes, "base64");
  if (video?.uri) {
    const token = await authClient.getAccessToken();
    const res = await fetch(video.uri, { headers: { Authorization: `Bearer ${token.token}` } });
    if (!res.ok) throw new Error(`could not download the rendered video (${res.status})`);
    return Buffer.from(await res.arrayBuffer());
  }
  throw new Error("no video in response");
}

/** First frame of the finished mp4 as the grid thumb, via ffmpeg → sharp. */
async function writeThumb(item: CatalogItem) {
  const proc = spawnSync(
    "ffmpeg",
    ["-v", "error", "-i", path.join(OUT_DIR, `${item.id}.mp4`), "-frames:v", "1", "-f", "image2pipe", "-vcodec", "png", "-"],
    { maxBuffer: 64 * 1024 * 1024 }
  );
  const png = proc.stdout;
  if (proc.status !== 0 || !png || png.length === 0) {
    throw new Error(`ffmpeg could not read a poster frame: ${proc.stderr?.toString() ?? "unknown error"}`);
  }
  const frame = sharp(png);
  const { width = 0, height = 0 } = await frame.metadata();
  const scale = THUMB_EDGE / Math.max(width, height, 1);
  const thumb = await frame
    .resize(Math.round(width * scale), Math.round(height * scale))
    .webp({ quality: 75, smartSubsample: true })
    .toBuffer();
  await writeFile(path.join(OUT_DIR, `${item.id}.thumb.webp`), thumb);
}

/** Vision pass over the poster frame: extracts the concrete, searchable
 * keywords for what is actually visible — objects, animals, people, setting,
 * and time/weather. */
async function tagOne(client: GoogleGenAI, item: CatalogItem): Promise<string[]> {
  const thumb = await readFile(path.join(OUT_DIR, `${item.id}.thumb.webp`));
  const response = await client.models.generateContent({
    model: TAG_MODEL,
    contents: [
      {
        role: "user",
        parts: [
          { inlineData: { mimeType: "image/webp", data: thumb.toString("base64") } },
          {
            text: "List 10-20 search keywords for everything visible in this image: every distinct object (e.g. tree, dog, cup, laptop), animals, people, the setting (e.g. beach, road, office, forest), and time of day or weather if evident. Lowercase, one or two words each. Respond with a JSON array of strings only.",
          },
        ],
      },
    ],
    config: { responseMimeType: "application/json" },
  });
  const parsed = JSON.parse(response.text ?? "[]") as unknown;
  if (!Array.isArray(parsed)) throw new Error("tag response is not an array");
  const tags = parsed
    .filter((t): t is string => typeof t === "string")
    .map((t) => t.trim().toLowerCase())
    .filter(Boolean);
  if (tags.length === 0) throw new Error("no tags in response");
  return [...new Set(tags)];
}

/** Tags from the current manifest, keyed by id — reused so re-runs only call
 * the vision model for new or untagged clips. */
async function existingTags(): Promise<Map<string, string[]>> {
  const byId = new Map<string, string[]>();
  try {
    const { STOCK_VIDEOS } = await import("../src/cut/lib/stockVideoManifest");
    for (const entry of STOCK_VIDEOS as { id: string; tags?: string[] }[]) {
      if (entry.tags?.length) byId.set(entry.id, entry.tags);
    }
  } catch {
    // No manifest yet — every clip gets a fresh tagging pass.
  }
  return byId;
}

async function writeManifest(done: Set<string>, tags: Map<string, string[]>) {
  const entries = CATALOG.filter((c) => done.has(c.id)).map((c) => ({
    id: c.id,
    category: c.category,
    prompt: c.prompt,
    tags: tags.get(c.id) ?? [],
    aspect: c.aspect,
    file: `/cut-stock-video/${c.id}.mp4`,
    thumb: `/cut-stock-video/${c.id}.thumb.webp`,
    duration: c.seconds,
  }));
  const body = `// Generated by scripts/generate-stock-videos.ts — do not edit by hand.
import type { StockVideo } from "./stock";

export const STOCK_VIDEOS: StockVideo[] = ${JSON.stringify(entries, null, 2)};
`;
  await writeFile(MANIFEST, body);
}

async function main() {
  const { client, authClient, project } = makeClient();
  await mkdir(OUT_DIR, { recursive: true });

  const done = new Set<string>(CATALOG.filter((c) => existsSync(path.join(OUT_DIR, `${c.id}.mp4`))).map((c) => c.id));
  const todo = CATALOG.filter((c) => !done.has(c.id));
  console.log(`model=${MODEL} project=${project} existing=${done.size} generating=${todo.length}`);

  let failed = 0;
  const queue = [...todo];
  const worker = async () => {
    for (let item = queue.shift(); item; item = queue.shift()) {
      for (let attempt = 1; ; attempt++) {
        try {
          const video = await generateOne(client, authClient, item);
          await writeFile(path.join(OUT_DIR, `${item.id}.mp4`), video);
          await writeThumb(item);
          done.add(item.id);
          console.log(`✓ ${item.id} (${item.aspect}, ${item.seconds}s)`);
          break;
        } catch (e) {
          if (attempt >= 2) {
            failed++;
            console.error(`✗ ${item.id}: ${e instanceof Error ? e.message : e}`);
            break;
          }
          console.warn(`retrying ${item.id}…`);
        }
      }
    }
  };
  await Promise.all(Array.from({ length: CONCURRENCY }, worker));

  // A finished clip can predate its thumb (an interrupted earlier run); fill in
  // any missing posters before tagging reads them.
  for (const item of CATALOG) {
    if (done.has(item.id) && !existsSync(path.join(OUT_DIR, `${item.id}.thumb.webp`))) {
      await writeThumb(item).catch((e) => console.error(`✗ thumb ${item.id}: ${e instanceof Error ? e.message : e}`));
    }
  }

  const tags = await existingTags();
  for (const item of CATALOG) {
    if (!done.has(item.id) || tags.has(item.id)) continue;
    try {
      tags.set(item.id, await tagOne(client, item));
      console.log(`✓ tags ${item.id}`);
    } catch (e) {
      failed++;
      console.error(`✗ tags ${item.id}: ${e instanceof Error ? e.message : e}`);
    }
  }

  await writeManifest(done, tags);
  console.log(`manifest: ${done.size}/${CATALOG.length} clips${failed ? `, ${failed} failed` : ""}`);
  if (failed) process.exitCode = 1;
}

await main();
