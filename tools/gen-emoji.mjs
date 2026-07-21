// Regenerates site/src/cut/lib/emoji.ts from the Unicode emoji list.
//
//   node tools/gen-emoji.mjs
//
// Fetches emoji-test.txt (UTS #51) if it isn't cached beside this script, then
// emits a categorized, searchable dataset. Skin-tone and hair variants are
// folded into their base emoji.

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const cache = join(here, "emoji-test.txt");
const outFile = join(here, "..", "site", "src", "cut", "lib", "emoji.ts");
const SRC = "https://unicode.org/Public/emoji/latest/emoji-test.txt";

if (!existsSync(cache)) {
  console.log(`fetching ${SRC}`);
  const res = await fetch(SRC);
  if (!res.ok) throw new Error(`fetch failed: ${res.status}`);
  writeFileSync(cache, await res.text());
}
const txt = readFileSync(cache, "utf8");

// Map Unicode CLDR groups → the picker's iPhone-style categories, in order.
const CATEGORY = {
  "Smileys & Emotion": "Smileys & People",
  "People & Body": "Smileys & People",
  "Animals & Nature": "Animals & Nature",
  "Food & Drink": "Food & Drink",
  Activities: "Activity",
  "Travel & Places": "Travel & Places",
  Objects: "Objects",
  Symbols: "Symbols",
  Flags: "Flags",
};
const ORDER = [
  "Smileys & People",
  "Animals & Nature",
  "Food & Drink",
  "Activity",
  "Travel & Places",
  "Objects",
  "Symbols",
  "Flags",
];

const cats = new Map(ORDER.map((c) => [c, []]));
const seen = new Set();
let group = null;
let subgroup = null;

for (const line of txt.split("\n")) {
  const g = line.match(/^# group: (.+)$/);
  if (g) {
    group = CATEGORY[g[1].trim()] ?? null;
    continue;
  }
  const s = line.match(/^# subgroup: (.+)$/);
  if (s) {
    subgroup = s[1].trim().replace(/-/g, " ");
    continue;
  }
  if (!group || line.startsWith("#") || !line.trim()) continue;

  const m = line.match(/;\s*fully-qualified\s*#\s*(\S+)\s+E[\d.]+\s+(.+)$/);
  if (!m) continue;
  const [, char, rawName] = m;
  const name = rawName.trim();
  // Skip skin-tone / hair-modifier variants — the base emoji stands in for all.
  if (/skin tone/i.test(name)) continue;
  if (seen.has(char)) continue;
  seen.add(char);

  // Search text: the emoji's name plus its subgroup, deduped words.
  const words = new Set(
    `${name} ${subgroup}`.toLowerCase().replace(/[^a-z0-9 ]/g, " ").split(/\s+/).filter(Boolean),
  );
  cats.get(group).push({ c: char, n: name, k: [...words].join(" ") });
}

const data = ORDER.map((name) => ({ name, emoji: cats.get(name) })).filter((c) => c.emoji.length);
const total = data.reduce((n, c) => n + c.emoji.length, 0);

const body = data
  .map(
    (c) =>
      `  {\n    name: ${JSON.stringify(c.name)},\n    emoji: [\n${c.emoji
        .map((e) => `      ${JSON.stringify([e.c, e.n, e.k])},`)
        .join("\n")}\n    ],\n  },`,
  )
  .join("\n");

const out = `// Generated from the Unicode emoji list (emoji-test.txt) by tools/gen-emoji.mjs.
// Do not edit by hand; rerun \`node tools/gen-emoji.mjs\` to refresh the set.
//
// Each emoji is [char, name, searchText]. Skin-tone and hair variants are
// folded into their base emoji. ${total} emoji across ${data.length} categories.

export type EmojiEntry = readonly [char: string, name: string, search: string];

export interface EmojiCategory {
  name: string;
  emoji: EmojiEntry[];
}

export const EMOJI_CATEGORIES: EmojiCategory[] = [
${body}
];
`;

writeFileSync(outFile, out);
console.log(`wrote ${outFile}: categories=${data.length} total=${total}`);
