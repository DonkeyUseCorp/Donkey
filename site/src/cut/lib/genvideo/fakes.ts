/**
 * A fake studio: every capability role, implemented in memory and instantly.
 *
 * This is how the whole pipeline — coverage, timing, voiceover, music,
 * lip-sync, placement, retry, fallback, model swapping — is exercised without a
 * credit spent or a browser. Each role records its calls so a test can assert
 * what ran, and the studio is configurable per role so an eval can build two
 * suites that differ by one model and compare them.
 */

import { MAX_SHOT_SEC, MIN_SHOT_SEC } from "./coverage";
import {
  segmentByDuration,
  type BreakdownInput,
  type ImageInput,
  type LipSyncInput,
  type ModelSuite,
  type MusicInput,
  type ReviewInput,
  type ReviewVerdict,
  type ScriptInput,
  type StyleBible,
  type VideoInput,
  type VideoTake,
  type VoiceInput,
  type VoiceResult,
} from "./capabilities";
import type { RawShot } from "./coverage";
import type { ScriptPlan, TranscriptWord } from "./types";

export interface FakeCall {
  role: string;
  detail: string;
  mediaId?: string;
  /** Video calls: which shot rendered, and from which seed keyframe — so a
   * test can prove seed-retention policies across retakes. */
  shotId?: string;
  keyframe?: string;
  /** Image/video calls: the full prompt, for asserting retake direction. */
  prompt?: string;
}

export interface FakeStudioOptions {
  label?: string;
  /** Reject every video whose prompt contains this marker (all attempts). */
  failVideoMarker?: string;
  /** This video model lip-syncs to audio itself — no lip-sync post-pass. */
  audioNative?: boolean;
  /** Tag on generated video ids, so an eval can tell suites apart. */
  videoVariant?: string;
  /** Beats the fake script writes when starting from a brief. */
  scriptBeats?: number;
  /** Force every voiceover to this many seconds (else derived from the line);
   * used to exercise a beat whose VO outruns one clip and spans several shots. */
  voiceSeconds?: number;
  /** Fail every image generation whose prompt contains this marker. */
  failImageMarker?: string;
  /** Make the style/character-design call throw (the run must fail loudly). */
  failStyle?: boolean;
  style?: string;
  /** Scripted dailies verdicts, consumed in order (absent = no review role).
   * Once the list runs dry every later take passes clean. */
  reviewVerdicts?: ReviewVerdict[];
  /** Simulate the provider refusing every image anchor: takes still render,
   * but unanchored (the real ladder's text rung) — how a person-policy block
   * on the seed looks to the orchestrator. */
  anchorsRefused?: boolean;
}

/** An in-memory studio; `.suite()` binds it to the orchestrator's roles. */
export class FakeStudio {
  readonly calls: FakeCall[] = [];
  private seq = 0;
  readonly label: string;

  constructor(private readonly opts: FakeStudioOptions = {}) {
    this.label = opts.label ?? "fake";
  }

  private mint(role: string, detail: string): string {
    const mediaId = `fake:${role}:${this.opts.videoVariant ?? "v"}:${this.seq++}`;
    this.calls.push({ role, detail, mediaId });
    return mediaId;
  }

  suite(): ModelSuite {
    const audioNative = !!this.opts.audioNative;
    return {
      label: this.label,
      script: { write: (i) => this.writeScript(i) },
      breakdown: { segment: (i) => this.segment(i) },
      style: { design: () => this.design() },
      image: { generate: (i) => this.image(i) },
      video: { generate: (i) => this.video(i), audioNative },
      voice: { speak: (i) => this.speak(i) },
      music: { compose: (i) => this.music(i) },
      ...(audioNative ? {} : { lipSync: { sync: (i: LipSyncInput) => this.lipSync(i) } }),
      transcribe: { transcribe: (id: string) => this.transcribe(id) },
      ...(this.opts.reviewVerdicts ? { review: { watch: (i: ReviewInput) => this.watch(i) } } : {}),
    };
  }

  private async watch(input: ReviewInput): Promise<ReviewVerdict> {
    const verdict = this.opts.reviewVerdicts?.shift() ?? { ok: true };
    this.calls.push({ role: "review", detail: `${input.videoMediaId} ok=${verdict.ok}` });
    return verdict;
  }

  private async writeScript(input: ScriptInput): Promise<ScriptPlan> {
    const n = this.opts.scriptBeats ?? Math.max(2, Math.round((input.targetSeconds ?? 30) / 6));
    const beats = Array.from({ length: n }, (_, i) => ({
      dialogue: `Line ${i + 1}: ${input.brief}`.slice(0, 80),
      action: i === 0 ? "establishing the scene" : "the story continues",
      characters: ["char:1"],
      location: "loc:1",
      framing: i === 0 ? "wide establishing shot" : "medium shot",
      approxSeconds: 6,
    }));
    this.calls.push({ role: "script", detail: `${n} beats from brief` });
    return { logline: input.brief, beats, style: this.opts.style };
  }

  private async segment(input: BreakdownInput): Promise<RawShot[]> {
    this.calls.push({ role: "breakdown", detail: `${input.durationFrames} frames` });
    return segmentByDuration(input, MAX_SHOT_SEC);
  }

  private async design(): Promise<StyleBible> {
    if (this.opts.failStyle) throw new Error("fake style design failed");
    this.calls.push({ role: "style", detail: "style bible" });
    return {
      style: this.opts.style ?? "Cinematic, natural light, shallow depth of field.",
      characters: [
        { id: "char:1", kind: "character", name: "the lead", description: "the person from the references" },
      ],
      locations: [{ id: "loc:1", kind: "location", name: "the setting", description: "the place the story lives" }],
    };
  }

  private async image(input: ImageInput): Promise<string> {
    const marker = this.opts.failImageMarker;
    if (marker && input.prompt.includes(marker))
      throw new Error(`fake image failed (marker "${marker}")`);
    const id = this.mint("image", input.prompt.slice(0, 40));
    this.calls[this.calls.length - 1].prompt = input.prompt;
    return id;
  }

  private async video(input: VideoInput): Promise<VideoTake> {
    const marker = this.opts.failVideoMarker;
    if (marker && input.prompt.includes(marker))
      throw new Error(`fake video failed (marker "${marker}")`);
    const id = this.mint("video", `${input.durationSec}s${input.audioMediaId ? " +audio" : ""} ${input.prompt}`);
    const call = this.calls[this.calls.length - 1];
    call.shotId = input.shotId;
    call.keyframe = input.startKeyframe;
    // Anchored when an anchor exists and the provider took it; refused
    // anchors fall to the words-only render, exactly like the real ladder.
    const anchored = !this.opts.anchorsRefused && (!!input.startKeyframe || input.refs.length > 0);
    return { mediaId: id, anchored };
  }

  private async speak(input: VoiceInput): Promise<VoiceResult> {
    // Length from the line (or forced via voiceSeconds). A line longer than one
    // clip is a real case — the orchestrator spans it across several shots.
    const raw = Math.max(1, input.script.length) * 0.06;
    const durationSec = this.opts.voiceSeconds ?? Math.max(MIN_SHOT_SEC, raw);
    return { mediaId: this.mint("voice", `${durationSec.toFixed(1)}s`), durationSec };
  }

  private async music(input: MusicInput): Promise<string> {
    return this.mint("music", `${input.mood} ${input.durationSec.toFixed(1)}s`);
  }

  private async lipSync(input: LipSyncInput): Promise<string> {
    return this.mint("lipsync", `sync ${input.videoMediaId}`);
  }

  private async transcribe(audioMediaId: string): Promise<TranscriptWord[]> {
    this.calls.push({ role: "transcribe", detail: audioMediaId });
    const words: TranscriptWord[] = [];
    for (let i = 0; i < 60; i++) words.push({ t0: i * 0.5, t1: i * 0.5 + 0.5, w: `word${i}` });
    return words;
  }
}

/** Convenience: a bound suite from options. */
export function fakeSuite(opts: FakeStudioOptions = {}): { suite: ModelSuite; studio: FakeStudio } {
  const studio = new FakeStudio(opts);
  return { suite: studio.suite(), studio };
}
