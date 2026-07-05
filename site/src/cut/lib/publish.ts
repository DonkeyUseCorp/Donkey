/** TikTok caption limit; hashtags, mentions, and emoji all count toward it. */
export const CAPTION_LIMIT = 4000;

/** "fyp, how to" → "#fyp #howto"-style hashtag line. */
export const normalizeTags = (raw: string) =>
  raw
    .split(/[\s,]+/)
    .map((t) => t.replace(/^#+/, ""))
    .filter(Boolean)
    .map((t) => `#${t}`)
    .join(" ");
