/**
 * Model-agnostic capability roles.
 *
 * The pipeline never names a provider. It asks for a capability by role —
 * "write the script", "generate a video", "sync lips to this audio" — and a
 * `ModelSuite` binds each role to some adapter. Provider names live only inside
 * those adapters (see `registry.ts`); swapping models is swapping which adapter
 * a role resolves to, and evals compare suites that differ by one role. The
 * orchestrator depends on this interface and nothing else model-facing.
 */

import type { RawShot } from "./coverage";
import type { RefAsset, ScriptBeat, ScriptPlan, TranscriptWord, VideoAsset } from "./types";

export type Aspect = "9:16" | "16:9";

export interface ScriptInput {
  brief: string;
  refs: RefAsset[];
  targetSeconds?: number;
}

export interface BreakdownInput {
  /** Present when an audio spine already exists (provided or generated VO). */
  transcript: TranscriptWord[];
  /** Present when the run started from a brief. */
  beats?: ScriptBeat[];
  durationFrames: number;
  fps: number;
}

export interface StyleInput {
  brief?: string;
  refs: RefAsset[];
  beats: { dialogue: string; action: string }[];
}

export interface StyleBible {
  /** The reusable style string every downstream prompt carries. */
  style: string;
  characters: VideoAsset[];
  locations: VideoAsset[];
}

export interface ImageInput {
  prompt: string;
  refs: RefAsset[];
  aspect: Aspect;
}

export interface VideoInput {
  prompt: string;
  refs: RefAsset[];
  startKeyframe?: string;
  endKeyframe?: string;
  /** The audio slice this shot should be spoken over — for audio-native video. */
  audioMediaId?: string;
  audioFromSec?: number;
  audioToSec?: number;
  durationSec: number;
  aspect: Aspect;
}

export interface VoiceInput {
  script: string;
  voice?: string;
  direction?: string;
}

export interface VoiceResult {
  mediaId: string;
  durationSec: number;
}

export interface MusicInput {
  mood: string;
  durationSec: number;
}

export interface LipSyncInput {
  videoMediaId: string;
  audioMediaId: string;
  fromSec?: number;
  toSec?: number;
}

export interface ScriptRole {
  write(input: ScriptInput): Promise<ScriptPlan>;
}
export interface BreakdownRole {
  segment(input: BreakdownInput): Promise<RawShot[]>;
}
export interface StyleRole {
  design(input: StyleInput): Promise<StyleBible>;
}
export interface ImageRole {
  /** Returns the generated project media id. */
  generate(input: ImageInput): Promise<string>;
}
export interface VideoRole {
  /** Returns the generated project media id. */
  generate(input: VideoInput): Promise<string>;
  /** True when this model lip-syncs to provided audio itself (no post-pass). */
  readonly audioNative: boolean;
}
export interface VoiceRole {
  speak(input: VoiceInput): Promise<VoiceResult>;
}
export interface MusicRole {
  /** Returns the generated project media id. */
  compose(input: MusicInput): Promise<string>;
}
export interface LipSyncRole {
  /** Returns a new video media id with mouths aligned to the audio. */
  sync(input: LipSyncInput): Promise<string>;
}
export interface TranscribeRole {
  transcribe(audioMediaId: string): Promise<TranscriptWord[]>;
}

/** One model choice per role — what the orchestrator runs against. */
export interface ModelSuite {
  /** Human label for evals and logs, e.g. "fast-video + hi-res-image". */
  label: string;
  script: ScriptRole;
  breakdown: BreakdownRole;
  style: StyleRole;
  image: ImageRole;
  video: VideoRole;
  voice: VoiceRole;
  music: MusicRole;
  /** Absent when `video.audioNative` — the video does its own lip-sync. */
  lipSync?: LipSyncRole;
  transcribe: TranscribeRole;
}

export type RoleName = keyof Omit<ModelSuite, "label">;

/** The deterministic segmenter — the breakdown fallback and the fake's brain. */
export function segmentByDuration(input: BreakdownInput, maxShotSec: number): RawShot[] {
  const { durationFrames, fps, transcript } = input;
  const maxFrames = Math.round(maxShotSec * fps);
  const count = Math.max(1, Math.ceil(durationFrames / maxFrames));
  const per = Math.floor(durationFrames / count);
  const shots: RawShot[] = [];
  for (let i = 0; i < count; i++) {
    const startFrame = i * per;
    const endFrame = i === count - 1 ? durationFrames : (i + 1) * per;
    shots.push({
      startFrame,
      endFrame,
      audioText: wordsInRange(transcript, startFrame / fps, endFrame / fps),
      action: "",
      characters: ["char:1"],
      location: "loc:1",
      framing: i === 0 ? "wide establishing shot" : "medium shot",
    });
  }
  return shots;
}

function wordsInRange(words: TranscriptWord[], from: number, to: number): string {
  return words.filter((w) => w.t1 > from && w.t0 < to).map((w) => w.w).join(" ");
}
