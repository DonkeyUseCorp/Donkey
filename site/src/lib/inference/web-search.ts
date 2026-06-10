import { GoogleGenAI } from "@google/genai";

import { geminiModelRoles } from "@/lib/inference/gemini-models";
import { geminiClientConfig } from "@/lib/inference/screenshot-parsing/gemini-flash";

export type WebSearchSource = {
  title: string;
  url: string;
};

export type WebSearchResult = {
  /** A short grounded answer to the query (from the model). */
  summary: string;
  /** The web sources the answer is grounded in. */
  sources: WebSearchSource[];
};

/**
 * Web search via Gemini's built-in Google Search grounding on Vertex AI. This uses the backend's
 * service-account credential (the same one behind live-token and screenshot parsing) — no API key
 * and no separate Programmable Search Engine. The model searches the web for the query and returns a
 * grounded summary plus the source pages it used, which the caller turns into ranked results.
 */
export async function searchWeb(query: string): Promise<WebSearchResult | null> {
  const config = geminiClientConfig();
  if (!config.configured) {
    return null;
  }
  const client = new GoogleGenAI(config.options);

  const response = await client.models.generateContent({
    model: geminiModelRoles.chat,
    contents: [
      {
        role: "user",
        parts: [
          {
            text:
              `Search the web and answer concisely: ${query}\n` +
              "Base the answer only on current web results.",
          },
        ],
      },
    ],
    config: {
      tools: [{ googleSearch: {} }],
      temperature: 0,
    },
  });

  const candidate = response.candidates?.[0];
  const summary = (response.text ?? "").trim();
  const chunks = candidate?.groundingMetadata?.groundingChunks ?? [];
  const sources: WebSearchSource[] = [];
  const seen = new Set<string>();
  for (const chunk of chunks) {
    const web = chunk.web;
    if (!web?.uri || seen.has(web.uri)) {
      continue;
    }
    seen.add(web.uri);
    sources.push({ title: web.title ?? web.uri, url: web.uri });
  }

  if (!summary && sources.length === 0) {
    return null;
  }
  return { summary, sources };
}
