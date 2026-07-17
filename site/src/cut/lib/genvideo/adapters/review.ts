"use client";

/**
 * The dailies reviewer — a multimodal judgment role that watches a rendered
 * take the way an editor screens footage: sampled frames of the clip ride to
 * the hosted model with the shot's planned action and the words heard over it,
 * and the verdict either passes the take (with the best in-point for the slot)
 * or declines it with a note the retake prompt carries.
 *
 * Frames come from the same in-browser capture the visual-subtitles pipeline
 * uses, so nothing renders server-side and the whole check is one cheap
 * structured call.
 */

import { geminiModelRoles } from "@/lib/inference/gemini-models";
import { hostedPost } from "../../hosted";
import { captureVideoFrames } from "../../visualFrames";
import { findRunAsset } from "../docWriter";
import type { ReviewInput, ReviewRole, ReviewVerdict } from "../capabilities";

const MAX_FRAMES = 8;
/** Aim for one frame every ~1s of take. */
const SECONDS_PER_FRAME = 1;

const REVIEW_INSTRUCTIONS = `You are a film editor reviewing one rendered take against its shot plan.
Reply with JSON only: {"ok": boolean, "note": string, "fromSec": number}
Rules:
- ok is whether the take shows the planned action and its subject. Judge content — the right person doing the right thing in the right place — and forgive style and small details.
- Any rendered text is an automatic fail: captions, subtitles, speech bubbles, titles, watermarks, or readable signs — note it as "remove every trace of on-screen text". A split screen, stacked panels, or a storyboard collage is also an automatic fail: the take must be one single continuous shot.
- Baked-in editing effects are an automatic fail: transition frames, fades to black or white, motion-blur smears, borders, or blurred letterbox bands — the picture must fill the frame edge to edge; the editor adds transitions later.
- note, when ok is false, is one short sentence naming what is wrong, written as direction for the retake ("the boy is reading, the plan wants him swimming").
- fromSec is where the needed window should start inside the take so its best moment lands in the window; 0 when the opening works. Stay within the take.`;

function frameTimes(clipSec: number): number[] {
  const count = Math.min(MAX_FRAMES, Math.max(3, Math.round(clipSec / SECONDS_PER_FRAME)));
  return Array.from({ length: count }, (_, i) => ((i + 0.5) * clipSec) / count);
}

function splitDataUrl(dataUrl: string): { mimeType: string; data: string } | null {
  const m = /^data:([^;,]+);base64,(.+)$/.exec(dataUrl);
  return m ? { mimeType: m[1], data: m[2] } : null;
}

export function makeReviewRole(projectId: string): ReviewRole {
  return {
    async watch(input: ReviewInput): Promise<ReviewVerdict> {
      // The take resolves wherever the run's project lives — store when open,
      // persisted doc when the user switched away mid-render.
      const asset = await findRunAsset(projectId, input.videoMediaId);
      if (!asset || asset.type !== "video") throw new Error("No take to review.");
      const clipSec = Math.max(0.1, asset.duration);
      const frames = await captureVideoFrames(asset.url, frameTimes(clipSec));
      if (frames.length === 0) throw new Error("Could not sample the take.");
      const content: Record<string, unknown>[] = [
        {
          text: `Review this take, shown as frames sampled along its ${clipSec.toFixed(1)}s.
Planned action: ${input.action || "(none written — judge against the narration)"}
Narration heard over the shot: ${input.narration ? `"${input.narration}"` : "(none)"}
The timeline slot needs ${input.slotSec.toFixed(1)}s of this take.`,
        },
      ];
      for (const f of frames) {
        const img = splitDataUrl(f.image);
        if (!img) continue;
        content.push({ text: `Frame at ${f.at.toFixed(1)}s:` });
        content.push({ type: "input_image", dataBase64: img.data, mimeType: img.mimeType });
      }
      const res = await hostedPost("/api/inference/responses", {
        donkeyProvider: "gemini",
        model: geminiModelRoles.chat,
        instructions: REVIEW_INSTRUCTIONS,
        response_format: { type: "json_object" },
        input: [{ role: "user", content }],
      });
      if (!res.ok) throw new Error("The review model is unavailable.");
      const body = (await res.json()) as { output_text?: string };
      const parsed = JSON.parse(body.output_text ?? "") as Record<string, unknown>;
      const ok = parsed.ok !== false;
      const note = typeof parsed.note === "string" ? parsed.note.trim() : "";
      const rawFrom = typeof parsed.fromSec === "number" && Number.isFinite(parsed.fromSec) ? parsed.fromSec : 0;
      const fromSec = Math.min(Math.max(0, rawFrom), Math.max(0, clipSec - input.slotSec));
      return { ok, ...(note ? { note } : {}), ...(fromSec > 0 ? { fromSec } : {}) };
    },
  };
}
