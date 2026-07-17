/**
 * The coverage invariant and the frame/second boundary.
 *
 * Shots must tile the whole audio with no gaps and no overlaps: the first
 * starts at frame 0, the last ends at `durationFrames`, and every shot ends
 * exactly where the next begins. Because frames are integers this holds
 * exactly — the orchestrator re-asserts it after every mutation, and any model
 * output is run through `repairCoverage` before it is trusted. `repairCoverage`
 * is total: it never throws for any input (a model routinely returns
 * overlapping, nested, or out-of-order ranges), and it treats a zero-length
 * timeline as covered by zero shots.
 *
 * Seconds cross this boundary only through `frameToSec`/`secToFrame`, computed
 * once from the project fps. Everything else in the plan is frames.
 */

import type { Shot } from "./types";

/** The timeline slice range a shot may occupy, in seconds. The floor is a
 * pacing choice, not the video model's: a narration names a new idea every
 * couple of seconds, and each idea deserves its own shot. The model's own
 * minimum render length lives in `supportedVideoDuration` — a short slot
 * renders the shortest supported take and the placement trims it to the slot
 * (the dailies review picks which window survives). The ceiling is the longest
 * single render. */
export const MIN_SHOT_SEC = 2;
export const MAX_SHOT_SEC = 8;

export const secToFrame = (sec: number, fps: number): number =>
  Math.max(0, Math.round(sec * fps));

export const frameToSec = (frame: number, fps: number): number => frame / fps;

export const shotDurationFrames = (shot: Shot): number =>
  shot.endFrame - shot.startFrame;

/** Thrown when the invariant is violated — a bug, not a user-facing error. */
export class CoverageError extends Error {}

/**
 * Assert the invariant. Throws `CoverageError` with the exact break. Call this
 * after every mutation to the shot list.
 */
export function assertCoverage(shots: Shot[], durationFrames: number): void {
  if (shots.length === 0) {
    if (durationFrames <= 0) return;
    throw new CoverageError(`No shots cover ${durationFrames} frames.`);
  }
  if (shots[0].startFrame !== 0)
    throw new CoverageError(`First shot starts at ${shots[0].startFrame}, not 0.`);
  const last = shots[shots.length - 1];
  if (last.endFrame !== durationFrames)
    throw new CoverageError(
      `Last shot ends at ${last.endFrame}, not ${durationFrames}.`
    );
  for (let i = 0; i < shots.length; i++) {
    const s = shots[i];
    if (s.endFrame <= s.startFrame)
      throw new CoverageError(
        `Shot ${s.id} is empty or inverted (${s.startFrame}..${s.endFrame}).`
      );
    if (i > 0 && s.startFrame !== shots[i - 1].endFrame)
      throw new CoverageError(
        `Gap or overlap between shot ${shots[i - 1].id} (ends ${
          shots[i - 1].endFrame
        }) and ${s.id} (starts ${s.startFrame}).`
      );
  }
}

/** A raw shot boundary from a model, before it is trusted. */
export interface RawShot {
  startFrame: number;
  endFrame: number;
  audioText?: string;
  action?: string;
  characters?: string[];
  location?: string;
  framing?: string;
}

/**
 * Force a raw boundary list into a valid, fully-covering, correctly-ordered
 * shot list. Sorts, clamps into range, chains the boundaries into a monotonic
 * contiguous sequence (dropping nested/overlapped ranges rather than inverting
 * them), merges any slice shorter than the minimum clip into a neighbor, and
 * splits any slice longer than the maximum clip. The result always passes
 * `assertCoverage`; a zero-length timeline yields zero shots.
 */
export function repairCoverage(
  raw: RawShot[],
  durationFrames: number,
  fps: number,
  makeId: (i: number) => string
): Shot[] {
  if (durationFrames <= 0) return [];
  const minFrames = Math.round(MIN_SHOT_SEC * fps);
  const maxFrames = Math.round(MAX_SHOT_SEC * fps);

  // Sort by start, drop degenerate, clamp into range.
  const sorted = raw
    .map((r) => ({
      startFrame: clampFrame(r.startFrame, durationFrames),
      endFrame: clampFrame(r.endFrame, durationFrames),
      audioText: r.audioText ?? "",
      action: r.action ?? "",
      characters: r.characters ?? [],
      location: r.location ?? "",
      framing: r.framing ?? "",
    }))
    .filter((r) => r.endFrame > r.startFrame)
    .sort((a, b) => a.startFrame - b.startFrame || a.endFrame - b.endFrame);

  // Chain into a contiguous, monotonic sequence. Walk in start order behind a
  // cursor at the end of the last kept shot: each kept shot starts at the
  // cursor and ends at its own clamped end, and any shot ending at or before
  // the cursor — a nested or fully-overlapped range — is dropped. Non-monotonic
  // model output can never produce a gap or an inverted shot this way.
  const live: Slice[] = [];
  let cursor = 0;
  for (const r of sorted) {
    const end = Math.min(r.endFrame, durationFrames);
    if (end <= cursor) continue; // already covered by an earlier, longer shot
    live.push({ ...r, startFrame: cursor, endFrame: end });
    cursor = end;
    if (cursor >= durationFrames) break;
  }
  if (live.length === 0) {
    live.push({ startFrame: 0, endFrame: durationFrames, audioText: "", action: "", characters: [], location: "", framing: "" });
  }
  live[live.length - 1].endFrame = durationFrames;

  // Merge too-short slices, then split too-long ones (split has the last word —
  // the minimum is half the maximum, so an even division never re-slivers).
  const merged = mergeShort(live, minFrames, durationFrames);
  const normalized = resplitOverMax(merged, maxFrames);

  const shots: Shot[] = normalized.map((r, i) => ({
    id: makeId(i),
    startFrame: r.startFrame,
    endFrame: r.endFrame,
    audioText: r.audioText,
    action: r.action,
    characters: r.characters,
    location: r.location,
    framing: r.framing,
    status: "pending",
    attempts: 0,
  }));

  assertCoverage(shots, durationFrames);
  return shots;
}

type Slice = {
  startFrame: number;
  endFrame: number;
  audioText: string;
  action: string;
  characters: string[];
  location: string;
  framing: string;
};

const unionIds = (a: string[], b: string[]): string[] => Array.from(new Set([...a, ...b]));
const joinText = (a: string, b: string): string => [a, b].filter(Boolean).join(" ").trim();

function mergeShort(slices: Slice[], minFrames: number, durationFrames: number): Slice[] {
  // If the whole thing is shorter than one minimum shot, it is one shot.
  if (durationFrames <= minFrames) {
    const first = slices[0];
    return [{ ...first, startFrame: 0, endFrame: durationFrames }];
  }
  const out: Slice[] = [];
  for (const s of slices) {
    const prev = out[out.length - 1];
    if (s.endFrame - s.startFrame < minFrames && prev) {
      // Absorb the sliver forward, carrying its continuity metadata so a
      // character/location that appears only here isn't lost from the plan.
      prev.endFrame = s.endFrame;
      prev.characters = unionIds(prev.characters, s.characters);
      if (!prev.location) prev.location = s.location;
      if (!prev.action) prev.action = s.action;
      if (!prev.framing) prev.framing = s.framing;
      prev.audioText = joinText(prev.audioText, s.audioText);
    } else {
      out.push({ ...s });
    }
  }
  // A too-short head with no predecessor absorbs its successor instead.
  while (out.length > 1 && out[0].endFrame - out[0].startFrame < minFrames) {
    const head = out[0];
    const next = out[1];
    next.startFrame = head.startFrame;
    next.characters = unionIds(head.characters, next.characters);
    if (!next.location) next.location = head.location;
    if (!next.framing) next.framing = head.framing;
    next.audioText = joinText(head.audioText, next.audioText);
    out.shift();
  }
  out[0].startFrame = 0;
  out[out.length - 1].endFrame = durationFrames;
  return out;
}

function resplitOverMax(slices: Slice[], maxFrames: number): Slice[] {
  const out: Slice[] = [];
  for (const s of slices) {
    const len = s.endFrame - s.startFrame;
    if (len <= maxFrames) {
      out.push(s);
      continue;
    }
    const parts = Math.ceil(len / maxFrames);
    const base = Math.floor(len / parts);
    // Scope the transcript to each sub-part so a sub-clip carries only the words
    // spoken during its slice, not the whole original shot's span.
    const textParts = sliceWords(s.audioText, parts);
    let start = s.startFrame;
    for (let i = 0; i < parts; i++) {
      const end = i === parts - 1 ? s.endFrame : start + base;
      out.push({ ...s, startFrame: start, endFrame: end, audioText: textParts[i] });
      start = end;
    }
  }
  return out;
}

/** Split text into `parts` roughly-equal word chunks (in order). */
function sliceWords(text: string, parts: number): string[] {
  if (parts <= 1) return [text];
  const words = text.split(/\s+/).filter(Boolean);
  const out: string[] = [];
  for (let i = 0; i < parts; i++) {
    const from = Math.floor((i * words.length) / parts);
    const to = Math.floor(((i + 1) * words.length) / parts);
    out.push(words.slice(from, to).join(" "));
  }
  return out;
}

const clampFrame = (v: unknown, durationFrames: number): number => {
  const n = typeof v === "number" && Number.isFinite(v) ? Math.round(v) : 0;
  return Math.max(0, Math.min(durationFrames, n));
};
