/**
 * Brief-to-video: the persisted plan.
 *
 * One `VideoProject` is the single source of truth for a run — it survives
 * restarts (it rides `ProjectDoc.genvideo`) and drives resume and selective
 * regeneration. Everything here is data; the orchestrator (`orchestrator.ts`)
 * is the only thing that mutates it, and it re-asserts the coverage invariant
 * (`coverage.ts`) after every mutation.
 *
 * A run has one audio spine — either audio the user dropped in, or audio the
 * pipeline generates from a brief (a spoken script plus a music bed). Shots
 * tile that spine, and each shot's video is lip-synced to its slice, so the
 * two entry points ("animate this audio" and "make me a video of X") share the
 * same machinery.
 *
 * Units: the plan reasons in whole frames, never seconds. Frame boundaries are
 * integers, so "shot i ends exactly where shot i+1 begins" holds by
 * construction. Seconds appear only at the editor boundary (see coverage.ts).
 */

/** A reference the user brought, passed to generation as media not text. */
export interface RefAsset {
  mediaId: string;
  kind: "image" | "video" | "audio";
  /** What this reference anchors — identity, place, look, or motion. */
  purpose?: "character" | "location" | "style" | "motion";
  name?: string;
}

/** One beat of a generated script — a shot's worth of screen time. */
export interface ScriptBeat {
  dialogue: string; // spoken line (drives the voiceover and the lip-sync)
  action: string; // what happens on screen
  characters: string[];
  location: string;
  framing: string;
  approxSeconds: number;
}

export interface ScriptPlan {
  logline: string;
  beats: ScriptBeat[];
  style?: string;
}

/** A reference image the whole run carries — a character or a location. */
export interface VideoAsset {
  /** Stable id referenced by shots (e.g. "char:nova", "loc:kitchen"). */
  id: string;
  kind: "character" | "location";
  name: string;
  description: string;
  /** The generated (or user-provided) reference image, once resolved. */
  mediaId?: string;
}

export type ShotStatus =
  | "pending"
  | "keyframing"
  | "generating"
  | "lipsync"
  | "reviewing"
  | "placed"
  | "failed";

/** One contiguous slice of the audio spine, and the shot that covers it. */
export interface Shot {
  id: string;
  /** Inclusive start frame; `endFrame` is exclusive. */
  startFrame: number;
  endFrame: number;
  /** What is heard across this slice (from the transcript or the script). */
  audioText: string;
  /** The spoken line, when the run wrote its own script. */
  dialogue?: string;
  /** What happens on screen — the motion, the beat. Text, never refs. */
  action: string;
  characters: string[]; // character asset ids
  location: string; // location asset id ("" = unspecified)
  framing: string;
  startKeyframe?: string; // media asset id
  endKeyframe?: string; // media asset id
  /** The beat voiceover this shot lip-syncs to (generated mode). The voice is
   * placed once per beat; a shot spans a slice of it (voiceFromSec..voiceToSec,
   * relative to the beat start), so a line longer than one clip is never cut. */
  voiceAssetId?: string;
  voiceFromSec?: number;
  voiceToSec?: number;
  clip?: string; // generated video, media asset id
  timelineClipId?: string; // the clip placed on the timeline
  lipSynced?: boolean;
  status: ShotStatus;
  attempts: number;
  lastPrompt?: string;
  error?: string;
}

/** One beat's voiceover placed on the soundtrack — the unit the spine is
 * placed in, so a video regeneration never restacks narration. */
export interface BeatVoice {
  /** The voiced clip's asset id. Absent while the plan is still on estimated
   * lengths (pre-approval); set once the beat is voiced. */
  voiceAssetId?: string;
  startFrame: number;
  durationFrames: number;
  /** The placed soundtrack clip id, once on the timeline (idempotent placement). */
  voiceClipId?: string;
}

export type AudioMode = "provided" | "generated";

/** The whole run. Persisted to disk as `ProjectDoc.genvideo`. */
export interface VideoProject {
  id: string;
  /** The free-text request when the run started from a brief. */
  brief: string;
  /** User-supplied references (images, video, audio) — may be empty. */
  references: RefAsset[];
  /** Where the audio spine comes from. */
  audioMode: AudioMode;
  /** Provided mode: the dropped audio clip + its asset. */
  audioClipId?: string;
  audioAssetId?: string;
  /** Generated mode: the written script, the voiced spine, and the music bed. */
  script?: ScriptPlan;
  beatVoices?: BeatVoice[];
  musicAssetId?: string;
  /** The placed music-bed clip id, once on the timeline (idempotent placement). */
  musicClipId?: string;
  /** Target length when generating from a brief (seconds). */
  targetSeconds?: number;
  fps: number;
  durationFrames: number;
  /** Word-level transcript of the spine (provided mode, or generated VO). */
  transcript: TranscriptWord[];
  /** The shape every render matches. Captured at start and refrozen at the
   * approval gate (the last moment the user can set it), so a render that
   * finishes after a project switch can never pick up another project's shape. */
  aspect?: "9:16" | "16:9";
  /** Reusable style string every downstream prompt carries. */
  style: string;
  /** The suite label the run was produced with (for provenance and evals). */
  suiteLabel: string;
  /** The chat thread that owns this run's media, so every asset it creates is
   * tagged to the chat (kept off the Media/Video/Image/Audio panels) and a
   * resume after reload keeps tagging with the same owner. */
  chatId?: string;
  characters: VideoAsset[];
  locations: VideoAsset[];
  shots: Shot[];
  phase: VideoPhase;
  breakdownApproved: boolean;
  createdAt: number;
  /** Epoch ms when the user approved and rendering began — the card's render
   * clock counts from here across reloads and project switches. */
  renderStartedAt?: number;
  updatedAt: number;
}

export type VideoPhase =
  | "brief"
  | "voicing"
  | "ingest"
  | "breakdown"
  | "style"
  | "keyframes"
  | "generating"
  | "review"
  | "polish"
  | "done"
  | "failed";

/** A transcribed word with timeline timing (seconds, as the engine returns). */
export interface TranscriptWord {
  t0: number;
  t1: number;
  w: string;
}

/** A progress event the chat panel and timeline both listen to. */
export type VideoEvent =
  | { type: "phase"; phase: VideoPhase; note?: string }
  | { type: "shot:update"; shot: Shot }
  | { type: "breakdown"; shots: Shot[] }
  | { type: "progress"; placed: number; total: number }
  | { type: "log"; message: string }
  /** The live ticker: one line on what the run is doing right now. */
  | { type: "activity"; message: string }
  | { type: "error"; message: string };

export type VideoEmit = (event: VideoEvent) => void;
