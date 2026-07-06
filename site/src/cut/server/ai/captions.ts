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

export async function rewriteCaptions(cues: CaptionInput[], style: string): Promise<string[]> {
  const originals = cues.map((c) => c.text);
  const numbered = cues.map((c, i) => `${i + 1}. ${c.text}`).join("\n");
  const guide = STYLE_GUIDE[style] ?? STYLE_GUIDE.clean;
  const prompt = `You rewrite spoken-word transcript lines into short-form social video captions (TikTok / Reels / Shorts).

Rewrite EACH numbered line below. Rules:
- Return EXACTLY ${cues.length} lines — one rewrite per input line, in the same order.
- Preserve the meaning and point of each original line.
- Keep each caption short so it fits inside the vertical video frame — about 3–8 words. It may wrap onto two lines, but must never be so long it would overflow the frame width.
- Sprinkle a few relevant emoji across the whole set — not every line, never more than one per line.
- Line 1 is the opener: make it a scroll-stopping hook.
- ${guide}

Return ONLY a JSON array of ${cues.length} strings. No commentary, no code fence.

Lines:
${numbered}`;

  let text: string;
  try {
    text = await Promise.race([runOnce(prompt), timeout(90_000)]);
  } catch {
    return originals;
  }
  const arr = parseStringArray(text);
  if (!arr || arr.length !== cues.length) return originals;
  return arr.map((s, i) => (s && s.trim() ? s.trim() : originals[i]));
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
