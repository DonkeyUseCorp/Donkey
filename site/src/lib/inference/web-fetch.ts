import { Defuddle } from "defuddle/node";
import { parseHTML } from "linkedom";

export type WebFetchResult = {
  title: string;
  /** The page's main content as clean markdown (nav/ads/boilerplate removed). */
  markdown: string;
  author?: string;
  published?: string;
  wordCount?: number;
};

const FETCH_TIMEOUT_MS = 20_000;
const MAX_BYTES = 5_000_000;

/**
 * Read a web page and return just its main content as clean markdown. Uses Defuddle (a modern
 * Readability successor built for markdown) over a linkedom DOM to strip nav, sidebars, ads, and
 * boilerplate, so the model gets the article — headings, links, lists intact — instead of raw HTML
 * or a flattened tag-strip. Runs on the backend so credentials/IP stay server-side; SSRF-guarded to
 * public http(s) only.
 */
export async function fetchWebContent(rawUrl: string): Promise<WebFetchResult | null> {
  const url = safePublicURL(rawUrl);
  if (!url) {
    return null;
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
  let html: string;
  try {
    const response = await fetch(url, {
      signal: controller.signal,
      redirect: "follow",
      headers: {
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Donkey/1.0",
        Accept: "text/html,application/xhtml+xml",
      },
    });
    if (!response.ok) {
      return null;
    }
    const contentType = response.headers.get("content-type") ?? "";
    if (contentType && !/html|xml|text/i.test(contentType)) {
      return null;
    }
    html = await readBounded(response);
  } catch {
    return null;
  } finally {
    clearTimeout(timeout);
  }

  try {
    const { document } = parseHTML(html);
    const result = await Defuddle(document, url, { markdown: true });
    const markdown = (result.content ?? "").trim();
    if (!markdown) {
      return null;
    }
    return {
      title: (result.title ?? "").trim(),
      markdown,
      author: result.author?.trim() || undefined,
      published: result.published?.trim() || undefined,
      wordCount: typeof result.wordCount === "number" ? result.wordCount : undefined,
    };
  } catch {
    return null;
  }
}

/** Only public http(s) URLs — reject other schemes and obvious internal/loopback/metadata hosts. */
function safePublicURL(rawUrl: string): string | null {
  let parsed: URL;
  try {
    parsed = new URL(rawUrl);
  } catch {
    return null;
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    return null;
  }
  const host = parsed.hostname.toLowerCase();
  const blocked =
    host === "localhost" ||
    host === "0.0.0.0" ||
    host === "169.254.169.254" || // cloud metadata
    host.endsWith(".localhost") ||
    host.endsWith(".internal") ||
    /^127\./.test(host) ||
    /^10\./.test(host) ||
    /^192\.168\./.test(host) ||
    /^172\.(1[6-9]|2\d|3[01])\./.test(host);
  return blocked ? null : parsed.toString();
}

/** Read the response body but stop at MAX_BYTES so a huge page can't blow up memory. */
async function readBounded(response: Response): Promise<string> {
  const reader = response.body?.getReader();
  if (!reader) {
    return await response.text();
  }
  const decoder = new TextDecoder();
  let total = 0;
  let out = "";
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    out += decoder.decode(value, { stream: true });
    if (total > MAX_BYTES) {
      await reader.cancel();
      break;
    }
  }
  return out;
}
