// The caption-AI prompts, shared verbatim by both backends: the engine's
// Claude one-shots (captions.ts, visualSubtitles.ts) and the hosted Gemini
// twin (../cloud/captions.ts). Only the model differs between the two — the
// asks must never drift apart.

export interface CaptionInput {
  start: number;
  end: number;
  text: string;
}

export const STYLE_GUIDE: Record<string, string> = {
  clean: "Keep it clear and natural — a light polish, not a rewrite.",
  hook: "Open with a strong curiosity gap that makes people need to keep watching; stay punchy throughout.",
  punchy: "Bold, high-energy phrasing. Make the opening line especially loud and impossible to scroll past.",
};

/** Cues per model call. A long track runs as several small calls — each one
 * finishes well inside the timeout, and a hiccup costs one batch, not the
 * whole track. */
export const BATCH_SIZE = 30;
export const BATCH_CONCURRENCY = 3;
export const BATCH_TIMEOUT_MS = 90_000;

/** The locale tag as an English language name for the prompt ("es" → "Spanish");
 * an unknown tag still reads fine raw. */
export function languageName(locale: string): string {
  try {
    return new Intl.DisplayNames(["en"], { type: "language" }).of(locale) ?? locale;
  } catch {
    return locale;
  }
}

export function rewritePrompt(cues: CaptionInput[], guide: string, isOpener: boolean): string {
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

export function translatePrompt(cues: CaptionInput[], language: string): string {
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

export function visualSubtitlesPrompt(duration: number, locale?: string): string {
  return `You caption silent short-form videos (TikTok / Reels / Shorts). Below are frames sampled from a ${duration.toFixed(1)}-second video, each labeled with its timeline time. Watch what happens across them and write narration captions that tell that story.

Rules:
- Return ONLY a JSON array: [{"start": seconds, "end": seconds, "text": "caption"}]. No commentary, no code fence.
- Chronological, non-overlapping cues covering the video from 0 to ${duration.toFixed(1)}s.
- Each cue runs 1.5–4 seconds; each text is 2–8 punchy words.
- Narrate what is on screen — actions, changes, the point — not camera trivia.
- Make the first cue a scroll-stopping hook.
- Write in the language of locale "${locale ?? "en-US"}".`;
}
