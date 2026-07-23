import os from "node:os";
import { query } from "@anthropic-ai/claude-agent-sdk";

// Rewrite plain transcript cues into punchy social-video captions, one-to-one so
// the timings stay put. Runs through the user's own Claude login (no hosted
// models), like the rest of Cut's AI. Any failure falls back to the originals.

export interface CaptionInput {
  start: number;
  end: number;
  text: string;
}

const STYLE_GUIDE: Record<string, string> = {
  clean: "Keep it clear and natural — a light polish, not a rewrite.",
  hook: "Open with a strong curiosity gap that makes people need to keep watching; stay punchy throughout.",
  punchy: "Bold, high-energy phrasing. Make the opening line especially loud and impossible to scroll past.",
};

const MODEL = "claude-haiku-4-5-20251001";

/** Cues per model call. A long track runs as several small calls — each one
 * finishes well inside the timeout, and a hiccup costs one batch, not the
 * whole track. */
const BATCH_SIZE = 30;
const BATCH_CONCURRENCY = 3;
const BATCH_TIMEOUT_MS = 90_000;

export async function rewriteCaptions(cues: CaptionInput[], style: string): Promise<string[]> {
  const guide = STYLE_GUIDE[style] ?? STYLE_GUIDE.clean;
  const batches = chunk(cues, BATCH_SIZE);
  const texts = await mapLimit(batches, BATCH_CONCURRENCY, async (batch, index) => {
    try {
      return await runBatch(rewritePrompt(batch, guide, index === 0), batch.length);
    } catch {
      return batch.map((c) => c.text);
    }
  });
  return texts.flat().map((s, i) => (s && s.trim() ? s.trim() : cues[i].text));
}

/** Translate cues one-to-one into the target locale's language, timings
 * untouched. Unlike the style rewrite, a failed translation throws — falling
 * back to the source language would silently fill the track with wrong text.
 * Each batch gets one retry first: timeouts and malformed replies are
 * transient. */
export async function translateCaptions(cues: CaptionInput[], locale: string): Promise<string[]> {
  let language = locale;
  try {
    language = new Intl.DisplayNames(["en"], { type: "language" }).of(locale) ?? locale;
  } catch {
    /* unknown locale tag — the raw tag still reads fine in the prompt */
  }
  const batches = chunk(cues, BATCH_SIZE);
  const texts = await mapLimit(batches, BATCH_CONCURRENCY, async (batch) => {
    try {
      return await runBatch(translatePrompt(batch, language), batch.length);
    } catch {
      return await runBatch(translatePrompt(batch, language), batch.length);
    }
  });
  return texts.flat().map((s, i) => (s && s.trim() ? s.trim() : cues[i].text));
}

function rewritePrompt(cues: CaptionInput[], guide: string, isOpener: boolean): string {
  const numbered = cues.map((c, i) => `${i + 1}. ${c.text}`).join("\n");
  return `You rewrite spoken-word transcript lines into short-form social video captions (TikTok / Reels / Shorts).

Rewrite EACH numbered line below. Rules:
- Return EXACTLY ${cues.length} lines — one rewrite per input line, in the same order.
- Preserve the meaning and point of each original line.
- Keep each caption short so it fits inside the vertical video frame — about 3–8 words. It may wrap onto two lines, but must never be so long it would overflow the frame width.
- Sprinkle a few relevant emoji across the whole set — not every line, never more than one per line.
${isOpener ? "- Line 1 is the opener: make it a scroll-stopping hook.\n" : ""}- ${guide}

Return ONLY a JSON array of ${cues.length} strings. No commentary, no code fence.

Lines:
${numbered}`;
}

function translatePrompt(cues: CaptionInput[], language: string): string {
  const numbered = cues.map((c, i) => `${i + 1}. ${c.text}`).join("\n");
  return `You translate subtitle lines for a short-form social video.

Translate EACH numbered line below into ${language}. Rules:
- Return EXACTLY ${cues.length} lines — one translation per input line, in the same order.
- Translate naturally, preserving the meaning and tone — not word-for-word.
- Mirror the original's brevity: each caption must stay short enough to fit in a vertical video frame.
- Keep emoji, proper names, and numbers as they are.

Return ONLY a JSON array of ${cues.length} strings. No commentary, no code fence.

Lines:
${numbered}`;
}

/** One model call for one batch: raced against the timeout, parsed, and length
 * checked. Throws on any shortfall so the caller decides between retry and
 * fallback. */
async function runBatch(prompt: string, expected: number): Promise<string[]> {
  const text = await Promise.race([runOnce(prompt), timeout(BATCH_TIMEOUT_MS)]);
  const arr = parseStringArray(text);
  if (!arr || arr.length !== expected) throw new Error("The reply came back malformed.");
  return arr;
}

function chunk<T>(items: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}

async function mapLimit<T, R>(
  items: T[],
  limit: number,
  fn: (item: T, index: number) => Promise<R>
): Promise<R[]> {
  const out = new Array<R>(items.length);
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.min(limit, items.length) }, async () => {
      while (next < items.length) {
        const i = next++;
        out[i] = await fn(items[i], i);
      }
    })
  );
  return out;
}

function timeout(ms: number): Promise<never> {
  return new Promise((_resolve, reject) => {
    setTimeout(() => reject(new Error("timeout")), ms).unref();
  });
}

async function runOnce(prompt: string): Promise<string> {
  const q = query({
    prompt,
    options: {
      model: MODEL,
      ...(process.env.DONKEY_CUT_CLAUDE
        ? { pathToClaudeCodeExecutable: process.env.DONKEY_CUT_CLAUDE }
        : {}),
      tools: [],
      permissionMode: "dontAsk",
      settingSources: [],
      maxTurns: 1,
      cwd: os.tmpdir(),
    },
  });
  let out = "";
  for await (const msg of q) {
    const m = msg as unknown as { type: string; subtype?: string; result?: unknown };
    if (m.type === "result" && m.subtype === "success" && typeof m.result === "string") {
      out = m.result;
    }
  }
  return out;
}

function parseStringArray(text: string): string[] | null {
  const start = text.indexOf("[");
  const end = text.lastIndexOf("]");
  if (start === -1 || end === -1 || end <= start) return null;
  try {
    const v = JSON.parse(text.slice(start, end + 1)) as unknown;
    return Array.isArray(v) ? v.map((x) => String(x)) : null;
  } catch {
    return null;
  }
}
