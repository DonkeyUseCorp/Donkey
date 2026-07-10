// Generates the bundled Cut stock-image catalog with the same Vertex image model
// the app uses (gemini-2.5-flash-image), then writes the typed manifest the
// editor imports. Idempotent: items whose file already exists are skipped, so
// re-running fills gaps or picks up new catalog entries only.
//
//   cd site && ./node_modules/.bin/bun scripts/generate-stock-images.ts
//
// Needs GOOGLE_APPLICATION_CREDENTIALS_JSON (bun auto-loads site/.env) and
// macOS `sips` to compress the raw PNGs into small JPEGs.

import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { GoogleGenAI } from "@google/genai";
import { JWT } from "google-auth-library";

import type { StockAspect, StockCategory } from "../src/cut/lib/stock";

interface CatalogItem {
  id: string;
  category: StockCategory;
  aspect: StockAspect;
  prompt: string;
}

const MODEL = process.env.GEMINI_IMAGE_MODEL?.trim() || "gemini-2.5-flash-image";
const OUT_DIR = path.join(import.meta.dirname, "..", "public", "cut-stock");
const MANIFEST = path.join(import.meta.dirname, "..", "src", "cut", "lib", "stockManifest.ts");
const CONCURRENCY = 4;
/** Longest image edge after compression — browse thumbnails, not print assets. */
const MAX_EDGE = 800;

const photo = (subject: string) =>
  `Professional stock photograph: ${subject} Natural lighting, shallow depth of field, sharp focus, realistic color grading. No text, no watermarks, no logos.`;

const anime = (subject: string) =>
  `High-quality anime illustration: ${subject} Clean line art, vibrant cel shading, detailed background, cinematic composition. No text, no watermarks.`;

const CATALOG: CatalogItem[] = [
  // Business
  { id: "business-boardroom", category: "Business", aspect: "16:9", prompt: photo("a diverse team in a modern boardroom reviewing charts and documents spread across a large table, mid-discussion.") },
  { id: "business-whiteboard", category: "Business", aspect: "9:16", prompt: photo("a young founder sketching a product flow on a glass whiteboard in a bright startup loft, colleagues watching.") },
  { id: "business-handshake", category: "Business", aspect: "16:9", prompt: photo("a close-up handshake between two professionals in a sunlit office lobby, blurred glass architecture behind.") },
  { id: "business-open-office", category: "Business", aspect: "16:9", prompt: photo("an open-plan office at golden hour, people working at standing desks, warm light streaming through tall windows.") },
  { id: "business-presentation", category: "Business", aspect: "16:9", prompt: photo("a woman presenting quarterly growth charts on a wall screen to an attentive small team in a conference room.") },
  { id: "business-desk-flatlay", category: "Business", aspect: "1:1", prompt: photo("a tidy flat-lay of a laptop, notebook, espresso cup, and phone on a light oak desk, viewed straight down.") },

  // Nature
  { id: "nature-misty-valley", category: "Nature", aspect: "16:9", prompt: photo("a misty mountain valley at sunrise, layered ridgelines fading into soft golden haze.") },
  { id: "nature-waterfall", category: "Nature", aspect: "16:9", prompt: photo("a tropical waterfall pouring into a clear jungle pool, lush ferns and volcanic rock around it.") },
  { id: "nature-dunes", category: "Nature", aspect: "16:9", prompt: photo("rippled sand dunes at dusk, long shadows and a deep orange-to-violet gradient sky.") },
  { id: "nature-pine-fog", category: "Nature", aspect: "9:16", prompt: photo("tall pine trees rising through morning fog, shot upward from the forest floor.") },
  { id: "nature-ocean-wave", category: "Nature", aspect: "16:9", prompt: photo("a turquoise ocean wave curling and catching backlight, spray frozen mid-air.") },
  { id: "nature-wildflowers", category: "Nature", aspect: "1:1", prompt: photo("a macro of wildflowers in a summer meadow, one poppy in crisp focus against a creamy bokeh field.") },

  // Travel
  { id: "travel-train-station", category: "Travel", aspect: "16:9", prompt: photo("two backpackers walking through a grand old train station, a vintage orange train waiting on the platform.") },
  { id: "travel-old-town", category: "Travel", aspect: "9:16", prompt: photo("a narrow cobblestone alley in a European old town, flower boxes on shutters, warm evening lanterns.") },
  { id: "travel-airplane-wing", category: "Travel", aspect: "16:9", prompt: photo("an airplane wing over a sea of sunset clouds, window-seat perspective.") },
  { id: "travel-boardwalk", category: "Travel", aspect: "16:9", prompt: photo("a wooden boardwalk lined with palm trees leading to a white-sand beach and clear shallow water.") },
  { id: "travel-balloons", category: "Travel", aspect: "16:9", prompt: photo("dozens of hot-air balloons drifting over a rocky valley at dawn, soft pastel sky.") },
  { id: "travel-flatlay", category: "Travel", aspect: "1:1", prompt: photo("a flat-lay of a passport, film camera, sunglasses, and a paper map with a marked route, viewed from above.") },

  // City
  { id: "city-skyline", category: "City", aspect: "16:9", prompt: photo("a modern city skyline across the water at blue hour, glass towers reflecting the last light.") },
  { id: "city-neon-crosswalk", category: "City", aspect: "9:16", prompt: photo("a rainy neon-lit crosswalk at night, umbrellas and reflections on wet asphalt.") },
  { id: "city-rooftop", category: "City", aspect: "16:9", prompt: photo("a rooftop terrace view over downtown at sunset, string lights in the foreground.") },
  { id: "city-subway", category: "City", aspect: "16:9", prompt: photo("a subway train arriving in motion blur while commuters wait on the platform.") },
  { id: "city-cafe-corner", category: "City", aspect: "16:9", prompt: photo("a sidewalk café on a leafy street corner, bicycles parked outside, morning light.") },
  { id: "city-aerial-grid", category: "City", aspect: "1:1", prompt: photo("a straight-down aerial of a busy city intersection, crosswalk stripes and tiny cars forming a clean grid.") },

  // Technology
  { id: "tech-coding", category: "Technology", aspect: "16:9", prompt: photo("a developer at a dual-monitor setup writing code in a dim room, screen glow on their face.") },
  { id: "tech-server-room", category: "Technology", aspect: "16:9", prompt: photo("a long server-room aisle with racks of blinking status lights fading into the distance.") },
  { id: "tech-circuit-macro", category: "Technology", aspect: "1:1", prompt: photo("a macro of a circuit board, gold traces and a CPU die in sharp focus, shallow depth of field.") },
  { id: "tech-robot-arm", category: "Technology", aspect: "16:9", prompt: photo("an industrial robot arm assembling components on a clean production line, cool white lighting.") },
  { id: "tech-vr-headset", category: "Technology", aspect: "9:16", prompt: photo("a person wearing a VR headset reaching out, lit by soft violet and cyan studio light.") },
  { id: "tech-dashboard", category: "Technology", aspect: "16:9", prompt: photo("a large monitor showing a clean analytics dashboard with charts, a blurred office behind it.") },

  // Anime
  { id: "anime-neon-street", category: "Anime", aspect: "9:16", prompt: anime("a rain-slicked neon city street at night, a figure with a glowing umbrella walking toward the viewer.") },
  { id: "anime-cherry-blossoms", category: "Anime", aspect: "16:9", prompt: anime("a student on a hilltop path under falling cherry blossoms, a town and sea far below.") },
  { id: "anime-mecha", category: "Anime", aspect: "16:9", prompt: anime("a giant mecha standing guard over a futuristic city at sunset, clouds parting dramatically.") },
  { id: "anime-ramen-shop", category: "Anime", aspect: "16:9", prompt: anime("a cozy late-night ramen shop interior, steam rising from bowls, warm lantern light.") },
  { id: "anime-floating-islands", category: "Anime", aspect: "16:9", prompt: anime("a fantasy landscape of floating islands with waterfalls spilling into the sky, airships drifting between them.") },
  { id: "anime-portrait", category: "Anime", aspect: "1:1", prompt: anime("a close-up portrait of a silver-haired adventurer with bright green eyes, wind-blown hair, golden-hour light.") },

  // Animal
  { id: "animal-retriever-beach", category: "Animal", aspect: "16:9", prompt: photo("a golden retriever sprinting along a beach at sunset, sand kicking up, ears flying.") },
  { id: "animal-cat-window", category: "Animal", aspect: "1:1", prompt: photo("a tabby cat sitting in soft window light, dust motes in the sunbeam.") },
  { id: "animal-fox-snow", category: "Animal", aspect: "16:9", prompt: photo("a red fox stepping through fresh snow in a quiet forest, breath visible in the cold air.") },
  { id: "animal-macaw", category: "Animal", aspect: "9:16", prompt: photo("a scarlet macaw perched on a branch, vivid red and blue feathers against deep green jungle bokeh.") },
  { id: "animal-elephants", category: "Animal", aspect: "16:9", prompt: photo("a family of elephants at a watering hole at dusk, golden dust in the air.") },
  { id: "animal-horse", category: "Animal", aspect: "16:9", prompt: photo("a chestnut horse galloping through a misty field at dawn, mane streaming.") },

  // Food & Drink
  { id: "food-brunch", category: "Food & Drink", aspect: "16:9", prompt: photo("a generous brunch spread on a rustic table: pancakes, fruit, coffee, and fresh juice, soft morning light.") },
  { id: "food-latte-art", category: "Food & Drink", aspect: "1:1", prompt: photo("a close-up of latte art in a ceramic cup on a marble counter, steam curling upward.") },
  { id: "food-sushi", category: "Food & Drink", aspect: "16:9", prompt: photo("an elegant sushi platter on dark slate, nigiri and rolls arranged with pickled ginger and wasabi.") },
  { id: "food-tacos", category: "Food & Drink", aspect: "16:9", prompt: photo("three street tacos with charred meat, cilantro, and lime on a paper-lined tray, market lights behind.") },
  { id: "food-smoothie-bowl", category: "Food & Drink", aspect: "9:16", prompt: photo("a vibrant berry smoothie bowl topped with granola, banana, and chia seeds, shot from a high angle.") },
  { id: "food-pizza", category: "Food & Drink", aspect: "16:9", prompt: photo("a wood-fired margherita pizza fresh from the oven, bubbling mozzarella and basil, embers glowing behind.") },
];

function makeClient(): { client: GoogleGenAI; project: string } {
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
  return { client, project: creds.project_id };
}

const aspectHint: Record<StockAspect, string> = {
  "16:9": "16:9 widescreen",
  "9:16": "9:16 vertical",
  "1:1": "1:1 square",
};

async function generateOne(client: GoogleGenAI, item: CatalogItem): Promise<Buffer> {
  const contents = [
    {
      role: "user",
      parts: [{ text: `${item.prompt}\n\nCompose the image in a ${aspectHint[item.aspect]} frame.` }],
    },
  ];
  // imageConfig pins the output aspect on models that honor it; the prompt line
  // above steers the rest. Fall back to prompt-only if the field is rejected.
  let response;
  try {
    response = await client.models.generateContent({
      model: MODEL,
      contents,
      config: {
        responseModalities: ["IMAGE", "TEXT"],
        imageConfig: { aspectRatio: item.aspect },
      } as Record<string, unknown>,
    });
  } catch {
    response = await client.models.generateContent({
      model: MODEL,
      contents,
      config: { responseModalities: ["IMAGE", "TEXT"] },
    });
  }
  const parts = response.candidates?.[0]?.content?.parts ?? [];
  for (const part of parts) {
    const data = part.inlineData?.data;
    if (data) return Buffer.from(data, "base64");
  }
  throw new Error("no image in response");
}

function compress(rawPng: string, outJpg: string) {
  execFileSync("sips", ["-Z", String(MAX_EDGE), "-s", "format", "jpeg", "-s", "formatOptions", "82", rawPng, "--out", outJpg], {
    stdio: "ignore",
  });
}

async function writeManifest(done: Set<string>) {
  const entries = CATALOG.filter((c) => done.has(c.id)).map((c) => ({
    id: c.id,
    category: c.category,
    prompt: c.prompt,
    aspect: c.aspect,
    file: `/cut-stock/${c.id}.jpg`,
  }));
  const body = `// Generated by scripts/generate-stock-images.ts — do not edit by hand.
import type { StockImage } from "./stock";

export const STOCK_IMAGES: StockImage[] = ${JSON.stringify(entries, null, 2)};
`;
  await writeFile(MANIFEST, body);
}

async function main() {
  const { client, project } = makeClient();
  await mkdir(OUT_DIR, { recursive: true });
  const tmp = path.join(os.tmpdir(), `cut-stock-${process.pid}`);
  await mkdir(tmp, { recursive: true });

  const done = new Set<string>(CATALOG.filter((c) => existsSync(path.join(OUT_DIR, `${c.id}.jpg`))).map((c) => c.id));
  const todo = CATALOG.filter((c) => !done.has(c.id));
  console.log(`model=${MODEL} project=${project} existing=${done.size} generating=${todo.length}`);

  let failed = 0;
  const queue = [...todo];
  const worker = async () => {
    for (let item = queue.shift(); item; item = queue.shift()) {
      for (let attempt = 1; ; attempt++) {
        try {
          const png = await generateOne(client, item);
          const raw = path.join(tmp, `${item.id}.png`);
          await writeFile(raw, png);
          compress(raw, path.join(OUT_DIR, `${item.id}.jpg`));
          done.add(item.id);
          console.log(`✓ ${item.id} (${item.aspect})`);
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
  await rm(tmp, { recursive: true, force: true });

  await writeManifest(done);
  console.log(`manifest: ${done.size}/${CATALOG.length} images${failed ? `, ${failed} failed` : ""}`);
  if (failed) process.exitCode = 1;
}

await main();
