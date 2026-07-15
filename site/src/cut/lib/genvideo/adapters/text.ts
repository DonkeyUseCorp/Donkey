"use client";

/**
 * The judgment roles — script, breakdown, style — as one-shot structured LLM
 * calls through Donkey's hosted Gemini (the same `/api/inference/responses`
 * json_object path prompt composition already uses). Each returns plain JSON we
 * validate in code; nothing here enforces a provider-side schema, matching how
 * the planner runs.
 *
 * The one contract that ties the three together: character and location ids.
 * The script (or breakdown) assigns stable ids — char:1, loc:1, … — and every
 * shot carries them. The style role is handed those exact ids and returns one
 * asset per id, so the reference images it designs tie back to the shots by
 * construction, not by hoping two independent calls agree.
 */

import { geminiModelRoles } from "@/lib/inference/gemini-models";
import { hostedPost } from "../../hosted";
import { NO_CREDITS_MESSAGE } from "../../generate";
import { secToFrame, type RawShot } from "../coverage";
import type { BreakdownRole, ScriptRole, StyleRole } from "../capabilities";
import type { ScriptBeat, ScriptPlan, TranscriptWord, VideoAsset } from "../types";

// ── the shared call ─────────────────────────────────────────────────────────

/** One structured JSON completion. `parse` returns null for unusable output,
 * which surfaces as a throw the caller (or the orchestrator) recovers from. */
async function llmJson<T>(
  instructions: string,
  userText: string,
  parse: (o: Record<string, unknown>) => T | null
): Promise<T> {
  const res = await hostedPost("/api/inference/responses", {
    donkeyProvider: "gemini",
    model: geminiModelRoles.chat,
    instructions,
    response_format: { type: "json_object" },
    input: [{ role: "user", content: [{ text: userText }] }],
  });
  if (!res.ok) {
    if (res.status === 402) throw new Error(NO_CREDITS_MESSAGE);
    if (res.status === 401) throw new Error("Sign in to Donkey to generate a video.");
    throw new Error("The planning model is unavailable — try again.");
  }
  const body = (await res.json()) as { output_text?: string };
  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(body.output_text ?? "") as Record<string, unknown>;
  } catch {
    throw new Error("The planning model returned unreadable output.");
  }
  const out = parse(parsed);
  if (out === null) throw new Error("The planning model returned an unusable plan.");
  return out;
}

// ── coercion helpers ────────────────────────────────────────────────────────

const str = (v: unknown): string => (typeof v === "string" ? v.trim() : "");
const num = (v: unknown, fallback: number): number =>
  typeof v === "number" && Number.isFinite(v) ? v : fallback;
const idList = (v: unknown): string[] =>
  Array.isArray(v) ? v.map((x) => String(x).trim()).filter(Boolean) : [];
const distinct = (xs: string[]): string[] => Array.from(new Set(xs.filter(Boolean)));

// ── script ──────────────────────────────────────────────────────────────────

const SCRIPT_INSTRUCTIONS = `You are a short-video writer. Turn the brief into a spoken video plan.
Reply with JSON only:
{"logline": string, "style": string, "beats": [
  {"dialogue": string, "action": string, "characters": ["char:1"], "location": "loc:1", "framing": string, "approxSeconds": number}
]}
Rules:
- dialogue is the narration/spoken line for that beat (one or two sentences), action is what is shown on screen.
- Assign each recurring character a stable id "char:1", "char:2", … and each place a stable id "loc:1", "loc:2", …; every beat lists the ids it uses. A beat with no character uses [].
- Keep the whole thing near the requested length; each beat is about 4–8 seconds of narration.
- style is a short reusable look for the whole video (medium, lighting, palette, mood), described by its visual traits — never a real brand, franchise, show, or artist name, even one the brief uses (a generator rejects trademarked names).`;

function parseScript(o: Record<string, unknown>): ScriptPlan | null {
  const rawBeats = Array.isArray(o.beats) ? o.beats : [];
  const beats: ScriptBeat[] = rawBeats
    .map((b): ScriptBeat => {
      const beat = (b ?? {}) as Record<string, unknown>;
      return {
        dialogue: str(beat.dialogue),
        action: str(beat.action),
        characters: idList(beat.characters),
        location: str(beat.location) || "loc:1",
        framing: str(beat.framing) || "medium shot",
        approxSeconds: Math.max(2, Math.min(8, num(beat.approxSeconds, 6))),
      };
    })
    .filter((b) => b.dialogue || b.action);
  if (beats.length === 0) return null;
  return {
    logline: str(o.logline),
    beats,
    style: typeof o.style === "string" && o.style.trim() ? o.style.trim() : undefined,
  };
}

export function makeScriptRole(): ScriptRole {
  return {
    async write(input) {
      const targetSeconds = Math.max(6, Math.min(90, input.targetSeconds ?? 24));
      const beatCount = Math.max(2, Math.min(14, Math.round(targetSeconds / 6)));
      const refNote = input.refs.length
        ? `The user attached ${input.refs.length} reference(s); keep the story consistent with them.`
        : "";
      const user = `Write a spoken video plan for this brief. Aim for about ${targetSeconds} seconds total across roughly ${beatCount} beats.
${refNote}
Brief: ${input.brief}`;
      return llmJson(SCRIPT_INSTRUCTIONS, user, parseScript);
    },
  };
}

// ── breakdown (provided-audio mode) ─────────────────────────────────────────

const BREAKDOWN_INSTRUCTIONS = `You are a shot-list editor. Break a narration into a shot list that tiles the whole timeline.
Reply with JSON only:
{"shots": [
  {"start": number, "end": number, "action": string, "characters": ["char:1"], "location": "loc:1", "framing": string}
]}
Rules:
- start/end are SECONDS on the timeline; the shots must run in order and cover the whole duration with no gaps.
- Each shot is about 4–8 seconds and its action describes what is shown while those words are heard.
- Assign stable ids: characters "char:1"…, locations "loc:1"…, reused across shots for continuity. A shot with no character uses [].`;

/** Compact, timed transcript for the model — capped so a long narration stays
 * within a sane prompt. Words are grouped into ~2s chunks with a start stamp. */
function timedTranscript(words: TranscriptWord[]): string {
  if (words.length === 0) return "(no transcript — pace the shots evenly)";
  const lines: string[] = [];
  let chunkStart = words[0].t0;
  let buf: string[] = [];
  const flush = () => {
    if (buf.length) lines.push(`[${chunkStart.toFixed(1)}s] ${buf.join(" ")}`);
    buf = [];
  };
  for (const w of words) {
    if (buf.length && w.t0 - chunkStart >= 2) {
      flush();
      chunkStart = w.t0;
    }
    buf.push(w.w);
    if (lines.length >= 200) break;
  }
  flush();
  return lines.join("\n");
}

function parseShots(o: Record<string, unknown>, fps: number): RawShot[] | null {
  const rawShots = Array.isArray(o.shots) ? o.shots : [];
  if (rawShots.length === 0) return null;
  const shots: RawShot[] = rawShots
    .map((s): RawShot => {
      const shot = (s ?? {}) as Record<string, unknown>;
      return {
        startFrame: secToFrame(num(shot.start, 0), fps),
        endFrame: secToFrame(num(shot.end, 0), fps),
        action: str(shot.action),
        characters: idList(shot.characters),
        location: str(shot.location) || "loc:1",
        framing: str(shot.framing) || "medium shot",
      };
    })
    .filter((s) => s.endFrame > s.startFrame);
  return shots.length > 0 ? shots : null;
}

export function makeBreakdownRole(): BreakdownRole {
  return {
    async segment(input) {
      const durSec = input.durationFrames / input.fps;
      const shotCount = Math.max(1, Math.round(durSec / 6));
      const user = `A ${durSec.toFixed(1)}s narration needs about ${shotCount} shots (each 4–8s) covering [0, ${durSec.toFixed(1)}].
Timed transcript:
${timedTranscript(input.transcript)}`;
      return llmJson(BREAKDOWN_INSTRUCTIONS, user, (o) => parseShots(o, input.fps));
    },
  };
}

// ── style bible ─────────────────────────────────────────────────────────────

const STYLE_INSTRUCTIONS = `You are an art director. Design the visual world for a short video.
Reply with JSON only:
{"style": string, "characters": [{"id": "char:1", "name": string, "description": string}], "locations": [{"id": "loc:1", "name": string, "description": string}]}
Rules:
- style is one reusable paragraph every shot carries: medium, lighting, palette, camera, mood.
- Return one entry per id you are asked to define, using those exact ids. description is a concrete visual of that subject/place (appearance, wardrobe, colors) so it stays consistent across shots.
- Never name a real brand, franchise, show, studio, or artist — not even one the brief names. A generator rejects a trademarked name, so translate any such reference into its concrete visual traits: linework, proportions, palette, shading, era. (e.g. a named 1990s TV cartoon → "hand-drawn 2D animation, thick black outlines, flat bright colors, exaggerated rounded features, yellow-toned skin, simple suburban backdrops".)`;

const DEFAULT_STYLE = "Cinematic, natural light, shallow depth of field.";

function toAssets(
  raw: unknown,
  ids: string[],
  kind: "character" | "location"
): VideoAsset[] {
  const list = Array.isArray(raw) ? (raw as Record<string, unknown>[]) : [];
  const byId = new Map(list.map((e) => [str(e.id), e]));
  return ids.map((id, i) => {
    const e = byId.get(id) ?? list[i] ?? {};
    return {
      id,
      kind,
      name: str(e.name) || (kind === "character" ? "the subject" : "the setting"),
      description: str(e.description) || (kind === "character" ? "the main subject" : "the scene"),
    };
  });
}

export function makeStyleRole(): StyleRole {
  return {
    async design(input) {
      const charIds = distinct(input.beats.flatMap((b) => b.characters ?? []));
      const locIds = distinct(input.beats.map((b) => b.location ?? "").filter(Boolean));
      const wantLocs = locIds.length ? locIds : ["loc:1"];
      const story = input.beats
        .map((b, i) => `${i + 1}. ${b.action}${b.dialogue ? ` — "${b.dialogue}"` : ""}`)
        .join("\n");
      const refNote = input.refs.length
        ? `The user attached ${input.refs.length} reference image(s) that fix how key subjects look; keep descriptions compatible with them.`
        : "";
      const user = `Design the look for this video.
Brief: ${input.brief || "(none)"}
${refNote}
Story:
${story}
Define these characters (use these exact ids): ${charIds.join(", ") || "(none)"}
Define these locations (use these exact ids): ${wantLocs.join(", ")}`;
      return llmJson(STYLE_INSTRUCTIONS, user, (o) => ({
        style: str(o.style) || DEFAULT_STYLE,
        characters: toAssets(o.characters, charIds, "character"),
        locations: toAssets(o.locations, wantLocs, "location"),
      }));
    },
  };
}
