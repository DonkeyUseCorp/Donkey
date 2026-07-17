/**
 * The brief-to-video orchestrator: a state machine, not a free-form loop.
 *
 * Phases run in order and the run is re-entrant — `run()` advances from
 * whatever phase the persisted project is in, so a restart resumes and a
 * follow-up turn re-enters for a subset of shots. The model is called only at
 * the genuine judgment points (script, breakdown, style); every other step is
 * deterministic. After every shot-list mutation the coverage invariant is
 * re-asserted, and the worker pool fills the track incrementally so the user
 * watches it populate.
 *
 *   brief → ingest → breakdown → (confirm) → style → keyframes → generating → polish → done
 *
 * A run has one audio spine — dropped-in audio, or a script the pipeline
 * voices plus a music bed. Shots tile the spine and each shot's video is
 * lip-synced to its slice: an audio-native video model does it inline, else a
 * lip-sync pass follows. Every placement is idempotent (a resume or a
 * regeneration swaps a clip in only once the replacement is ready), so no path
 * double-stacks video, voice, or music, and none leaves a hole in the track.
 */

import { assertCoverage, frameToSec, MAX_SHOT_SEC, MIN_SHOT_SEC, repairCoverage, secToFrame, shotDurationFrames } from "./coverage";
import { fanOut } from "./pool";
import { buildPrompt, buildRefPrompt, refsForAsset, shotRefs } from "./prompt";
import { segmentByDuration, type ModelSuite, type ReviewVerdict } from "./capabilities";
import type { EditorBridge } from "./editor";
import type { BeatVoice, RefAsset, Shot, VideoAsset, VideoEmit, VideoPhase, VideoProject } from "./types";

export interface OrchestratorDeps {
  editor: EditorBridge;
  suite: ModelSuite;
  emit: VideoEmit;
  /** Write the plan to disk (rides ProjectDoc.genvideo). */
  persist: (project: VideoProject) => void | Promise<void>;
  /** Workers in flight during generation (tuned to the provider's rate limit). */
  concurrency?: number;
  /** Injected sleep so tests run instantly. */
  sleep?: (ms: number) => Promise<void>;
}

const VIDEO_ATTEMPTS = 3; // the first try plus two retries
const REF_ATTEMPTS = 2; // extra retries for continuity anchors
const BACKOFF_MS = 500;
const VOICE_DUCK = 0.35;

export class VideoOrchestrator {
  /** Serializes persistence so concurrent shot updates never interleave writes. */
  private saveChain: Promise<void> = Promise.resolve();
  /** Set when a newer run supersedes this one (the user switched projects), so
   * in-flight work stops writing to the timeline or the persisted plan. */
  private aborted = false;

  constructor(public project: VideoProject, private readonly deps: OrchestratorDeps) {}

  /** Abandon this run: later phases and the persist chain become no-ops. Called
   * before a replacement orchestrator takes over, and when the run's project
   * stops being open, so nothing renders (or spends) against a project the
   * user has left. The persisted plan resumes via hydrate. */
  abort(): void {
    this.aborted = true;
  }

  /** Whether this run was superseded or paused — late settlements check this so
   * they never touch state a newer run now owns. */
  get isAborted(): boolean {
    return this.aborted;
  }

  /** The shape every keyframe and shot renders at. Frozen on the plan (captured
   * at start, refreshed at approval — the last moment the user can set it), so
   * a background render can never pick up another open project's shape. The
   * live read only backfills a plan persisted before the field existed. */
  private get aspect(): "9:16" | "16:9" {
    return this.project.aspect ?? this.deps.editor.getTimeline().aspect;
  }

  private get fps(): number {
    return this.project.fps;
  }
  private get durationFrames(): number {
    return this.project.durationFrames;
  }

  /** Advance the run from its current phase to the next stopping point. An
   * abort landing between phases stops the walk — no later phase may render or
   * spend once the run is superseded or paused. */
  async run(): Promise<VideoProject> {
    if (this.project.phase === "failed" || this.project.phase === "done") return this.project;
    const phases = [this.brief, this.ingest, this.breakdown];
    for (const phase of phases) {
      if (this.aborted) return this.project;
      await phase.call(this);
    }
    if (!this.project.breakdownApproved) return this.project; // wait for confirmation
    // The spine is voiced only now, past the gate, so an unapproved plan spends
    // nothing on TTS (the plan up to here runs on estimated beat lengths).
    const paid = [this.voice, this.style, this.keyframes, this.generateAndPlaceAll, this.polish];
    for (const phase of paid) {
      if (this.aborted) return this.project;
      await phase.call(this);
    }
    return this.project;
  }

  /** The user confirmed the shot list — continue the run. */
  async approveBreakdown(): Promise<VideoProject> {
    this.project.breakdownApproved = true;
    // The approval gate is the last moment the user can set the project shape;
    // freeze it now so every render matches, even after a project switch.
    this.project.aspect = this.deps.editor.getTimeline().aspect;
    await this.save();
    return this.run();
  }

  // ── Phase 0: brief → script → estimated shot plan (generated mode) ────────
  private async brief(): Promise<void> {
    if (this.project.audioMode !== "generated") return;
    if (this.project.shots.length > 0) return; // already planned (resume)
    this.setPhase("brief");
    if (!this.project.script) {
      this.project.script = await this.deps.suite.script.write({
        brief: this.project.brief,
        refs: this.project.references,
        targetSeconds: this.project.targetSeconds,
      });
      await this.save();
    }
    // Lay the plan out on *estimated* beat lengths (from word count) so the
    // confirmation card exists without spending a cent on TTS. The real voiced
    // lengths replace these in voice(), after the user approves; the music bed
    // is likewise deferred to polish.
    const minF = Math.round(MIN_SHOT_SEC * this.fps);
    const frames = this.project.script.beats.map((b) =>
      Math.max(minF, secToFrame(estimateSpokenSeconds(b.dialogue), this.fps))
    );
    this.layoutBeats(
      frames,
      this.project.script.beats.map(() => undefined)
    );
    await this.save();
  }

  // ── Phase 0b: voice the spine (generated mode, after the gate) ────────────
  private async voice(): Promise<void> {
    if (this.aborted) return;
    if (this.project.audioMode !== "generated" || !this.project.script) return;
    // Idempotent across resumes: done once every beat carries its asset id AND
    // the shots have been re-laid onto the voiced spine (a later resume must
    // never rebuild shots that already rendered).
    const voices = this.project.beatVoices ?? [];
    if (
      voices.length > 0 &&
      voices.every((bv) => bv.voiceAssetId) &&
      this.project.shots.every((s) => s.voiceAssetId)
    ) {
      return;
    }
    this.setPhase("voicing");
    // Voice each beat to get its true length; the voice is one clip per beat,
    // and a beat longer than one video clip spans several shots that each
    // lip-sync to their own slice — so a long line is never cut off. Each beat
    // persists as it lands, so an interruption never re-bills voiced beats.
    const minF = Math.round(MIN_SHOT_SEC * this.fps);
    const voiceIds: string[] = [];
    const frames: number[] = [];
    for (const [bi, beat] of this.project.script.beats.entries()) {
      if (this.aborted) return;
      const prior = voices[bi];
      if (prior?.voiceAssetId) {
        voiceIds.push(prior.voiceAssetId);
        frames.push(prior.durationFrames);
        continue;
      }
      this.deps.emit({ type: "activity", message: `Voicing line ${bi + 1} of ${this.project.script.beats.length}…` });
      const vo = await this.deps.suite.voice.speak({ script: beat.dialogue });
      const id = await this.deps.editor.importMedia(vo.mediaId);
      const dur = Math.max(minF, secToFrame(vo.durationSec, this.fps));
      voiceIds.push(id);
      frames.push(dur);
      if (prior) {
        prior.voiceAssetId = id;
        prior.durationFrames = dur;
        await this.save();
      }
    }
    if (this.aborted) return;
    // Move the approved shots onto the real lengths — boundaries scale within
    // each beat so no slice runs past its voice clip, but the shot list itself
    // (count, order, notes) stays exactly the plan the user approved.
    this.rescaleBeats(frames, voiceIds);
    await this.save();
    this.deps.emit({ type: "breakdown", shots: this.project.shots });
  }

  /** Scale the approved shots to the real voiced beat lengths. Each beat's
   * shots keep their relative proportions inside the beat's new span, so the
   * plan the user approved — shots, order, gate-time notes — is what renders;
   * only frame boundaries move. The one exception is physical: a voiced line
   * longer than the clip cap splits its shot into contiguous sub-shots (copies
   * carrying the same prompt fields), because one clip cannot span it. Falls
   * back to a fresh layout when there is no estimated spine to scale. */
  private rescaleBeats(beatFrames: number[], voiceIds: (string | undefined)[]): void {
    const old = this.project.beatVoices;
    if (!this.project.script || !old || old.length !== beatFrames.length) {
      this.layoutBeats(beatFrames, voiceIds);
      return;
    }
    // The estimated beat spans, from the untouched startFrames: voice() rewrites
    // each entry's durationFrames as beats land, but every startFrame (and the
    // total) stays the estimated layout until the rescale below moves the shots.
    const oldEnd = (bi: number) =>
      bi + 1 < old.length ? old[bi + 1].startFrame : this.project.durationFrames;
    const maxF = Math.round(MAX_SHOT_SEC * this.fps);
    let cursor = 0;
    const shots: Shot[] = [];
    const beatVoices: BeatVoice[] = [];
    this.project.script.beats.forEach((beat, bi) => {
      const ob = old[bi];
      const oldDur = Math.max(1, oldEnd(bi) - ob.startFrame);
      const dur = beatFrames[bi];
      const voiceId = voiceIds[bi];
      const beatStart = cursor;
      const slice = (s: number, e: number, base: Shot) => ({
        ...base,
        startFrame: s,
        endFrame: e,
        ...(voiceId ? { voiceAssetId: voiceId } : {}),
        voiceFromSec: frameToSec(s - beatStart, this.fps),
        voiceToSec: frameToSec(e - beatStart, this.fps),
      });
      let beatShots = this.project.shots.filter(
        (s) => s.startFrame >= ob.startFrame && s.startFrame < ob.startFrame + oldDur
      );
      if (beatShots.length === 0) {
        // Nothing to scale for this beat (a malformed persisted plan) — seed
        // one shot from the beat so coverage holds.
        beatShots = [
          {
            id: `shot:${bi}`,
            startFrame: beatStart,
            endFrame: beatStart + dur,
            audioText: beat.dialogue,
            dialogue: beat.dialogue,
            action: beat.action,
            characters: beat.characters,
            location: beat.location,
            framing: beat.framing,
            status: "pending",
            attempts: 0,
          },
        ];
      }
      let at = cursor;
      beatShots.forEach((shot, si) => {
        const frac = (shot.endFrame - ob.startFrame) / oldDur;
        const end =
          si === beatShots.length - 1
            ? beatStart + dur
            : Math.min(beatStart + dur, Math.max(at + 1, beatStart + Math.round(frac * dur)));
        const pieces = splitBeat(at, Math.max(1, end - at), maxF);
        pieces.forEach(([s, e], pi) => {
          shots.push(slice(s, e, pieces.length === 1 ? shot : { ...shot, id: `${shot.id}.${pi}` }));
        });
        at = end;
      });
      beatVoices.push({
        ...(voiceId ? { voiceAssetId: voiceId } : {}),
        startFrame: beatStart,
        durationFrames: dur,
      });
      cursor += dur;
    });
    this.project.durationFrames = cursor;
    this.project.shots = shots;
    this.project.beatVoices = beatVoices;
    assertCoverage(this.project.shots, this.durationFrames);
  }

  /** Lay shots + the beat spine out from per-beat frame lengths. Runs twice in
   * generated mode: brief() passes estimated lengths (no voice ids yet); voice()
   * passes the real voiced lengths and ids. */
  private layoutBeats(beatFrames: number[], voiceIds: (string | undefined)[]): void {
    if (!this.project.script) return;
    const maxF = Math.round(MAX_SHOT_SEC * this.fps);
    let cursor = 0;
    const shots: Shot[] = [];
    const beatVoices: BeatVoice[] = [];
    this.project.script.beats.forEach((beat, bi) => {
      const dur = beatFrames[bi];
      const beatStart = cursor;
      const voiceId = voiceIds[bi];
      beatVoices.push({
        ...(voiceId ? { voiceAssetId: voiceId } : {}),
        startFrame: beatStart,
        durationFrames: dur,
      });
      for (const [s, e] of splitBeat(beatStart, dur, maxF)) {
        shots.push({
          id: `shot:${shots.length}`,
          startFrame: s,
          endFrame: e,
          audioText: beat.dialogue,
          dialogue: beat.dialogue,
          action: beat.action,
          characters: beat.characters,
          location: beat.location,
          framing: beat.framing,
          ...(voiceId ? { voiceAssetId: voiceId } : {}),
          voiceFromSec: frameToSec(s - beatStart, this.fps),
          voiceToSec: frameToSec(e - beatStart, this.fps),
          status: "pending",
          attempts: 0,
        });
      }
      cursor += dur;
    });
    this.project.durationFrames = cursor;
    this.project.shots = shots;
    this.project.beatVoices = beatVoices;
    assertCoverage(this.project.shots, this.durationFrames);
  }

  // ── Phase A: ingest (provided mode) ──────────────────────────────────────
  private async ingest(): Promise<void> {
    if (this.project.audioMode !== "provided") return;
    if (this.project.transcript.length > 0 || !this.project.audioAssetId) return;
    this.setPhase("ingest");
    this.project.transcript = await this.deps.suite.transcribe.transcribe(this.project.audioAssetId);
    await this.save();
  }

  // ── Phase B: shot breakdown (provided mode) + confirmation gate ───────────
  private async breakdown(): Promise<void> {
    if (this.project.shots.length === 0) {
      this.setPhase("breakdown");
      const input = {
        transcript: this.project.transcript,
        ...(this.project.brief ? { brief: this.project.brief } : {}),
        durationFrames: this.durationFrames,
        fps: this.fps,
      };
      const id = (i: number) => `shot:${i}`;
      let shots: Shot[];
      try {
        shots = repairCoverage(await this.deps.suite.breakdown.segment(input), this.durationFrames, this.fps, id);
      } catch {
        shots = repairCoverage(segmentByDuration(input, MAX_SHOT_SEC), this.durationFrames, this.fps, id);
      }
      this.project.shots = shots;
      assertCoverage(this.project.shots, this.durationFrames);
      await this.save();
    }
    this.deps.emit({ type: "breakdown", shots: this.project.shots });
  }

  // ── Phase C: style bible + reference images ──────────────────────────────
  private async style(): Promise<void> {
    this.setPhase("style");
    if (!this.project.style || this.project.characters.length === 0) {
      try {
        const bible = await this.deps.suite.style.design({
          brief: this.project.brief,
          refs: this.project.references,
          beats: this.project.shots.map((s) => ({
            dialogue: s.dialogue ?? s.audioText,
            action: s.action,
            characters: s.characters,
            location: s.location,
          })),
        });
        this.project.style = bible.style;
        this.project.characters = bible.characters;
        this.project.locations = bible.locations;
      } catch {
        // Degrade to a default bible so identity anchors still exist — an empty
        // characters list would silently drop every reference image.
        if (!this.project.style) this.project.style = "Cinematic, natural light.";
        if (this.project.characters.length === 0)
          this.project.characters = [{ id: "char:1", kind: "character", name: "the subject", description: "the main subject, from the references" }];
        if (this.project.locations.length === 0)
          this.project.locations = [{ id: "loc:1", kind: "location", name: "the setting", description: "the scene" }];
      }
      await this.save();
    }
    const needed = this.referencedAssets().filter((a) => !a.mediaId);
    if (needed.length > 0) {
      await fanOut(
        needed,
        async (asset) => {
          if (this.aborted) return; // a paused run spends nothing more
          this.deps.emit({ type: "activity", message: `Designing ${asset.name}…` });
          const raw = await this.deps.suite.image.generate({
            prompt: buildRefPrompt(asset, this.project.style),
            refs: refsForAsset(asset, this.project),
            aspect: this.aspect,
          });
          asset.mediaId = await this.deps.editor.importMedia(raw);
          this.deps.emit({ type: "log", message: `Designed ${asset.name}.` });
        },
        this.poolOpts(REF_ATTEMPTS)
      );
      const missing = needed.filter((a) => !a.mediaId);
      if (missing.length)
        this.deps.emit({ type: "log", message: `Couldn't design ${missing.map((a) => a.name).join(", ")} — those shots may drift.` });
      await this.save();
    }
  }

  // ── Phase D: keyframes (cheap, run in parallel) ──────────────────────────
  private async keyframes(): Promise<void> {
    this.setPhase("keyframes");
    const need = this.project.shots.filter((s) => !s.startKeyframe && s.status !== "placed");
    if (need.length === 0) return;
    // Failures are fine here — a shot with no keyframe still gets a still sourced
    // in placeFallback, so nothing swallowed leaves a hole.
    await fanOut(need, (shot) => this.makeKeyframes(shot), this.poolOpts(1));
    await this.save();
  }

  private async makeKeyframes(shot: Shot): Promise<void> {
    if (this.aborted) return; // a paused run spends nothing more
    this.updateShot(shot, { status: "keyframing" });
    const refs = shotRefs(shot, this.project);
    const prompt = buildPrompt(shot, this.project);
    shot.startKeyframe = await this.importedImage(`${prompt} Opening frame.`, refs);
    if (hasMotion(shot)) shot.endKeyframe = await this.importedImage(`${prompt} Closing frame.`, refs);
    this.updateShot(shot, { status: "pending" });
  }

  // ── Phase E + F: generation fans out; each clip places when it lands ──────
  private async generateAndPlaceAll(): Promise<void> {
    if (this.aborted) return;
    this.setPhase("generating");
    await this.placeSpine();
    const pending = this.project.shots.filter((s) => s.status !== "placed");
    await fanOut(pending, (shot) => this.generateAndPlace(shot), this.poolOpts(0));
    this.emitProgress();
  }

  /** Place the generated voiceover, once per beat (idempotent across resumes). */
  private async placeSpine(): Promise<void> {
    if (this.project.audioMode !== "generated" || !this.project.beatVoices) return;
    let changed = false;
    for (const bv of this.project.beatVoices) {
      if (bv.voiceClipId || !bv.voiceAssetId) continue;
      bv.voiceClipId = await this.deps.editor.placeAudio(bv.voiceAssetId, bv.startFrame, bv.durationFrames, {
        kind: "voice",
        duck: VOICE_DUCK,
      });
      changed = true;
    }
    if (changed) await this.save();
  }

  private async generateAndPlace(shot: Shot): Promise<void> {
    if (this.aborted) return;
    const audio = this.audioForShot(shot);
    const basePrompt = buildPrompt(shot, this.project);
    const refs = shotRefs(shot, this.project);
    // The reviewer's note from a declined take — the retake prompt carries it.
    let critique: string | undefined;
    for (let attempt = 1; attempt <= VIDEO_ATTEMPTS; attempt++) {
      if (this.aborted) return; // a paused run spends nothing more
      shot.attempts = attempt;
      // Set per attempt, not once: a declined review leaves the shot in
      // "reviewing", and the retake that follows must show as rendering (this
      // is also what fires the "retake N…" ticker line).
      this.updateShot(shot, { status: "generating", error: undefined });
      const prompt = critique ? `${basePrompt} Note from the last take's review: ${critique}` : basePrompt;
      const video = this.deps.suite.video;
      try {
        let clip = await video.generate({
          prompt,
          refs,
          shotId: shot.id,
          startKeyframe: shot.startKeyframe,
          endKeyframe: shot.endKeyframe,
          durationSec: frameToSec(shotDurationFrames(shot), this.fps),
          aspect: this.aspect,
          ...(audio && video.audioNative
            ? { audioMediaId: audio.mediaId, audioFromSec: audio.fromSec, audioToSec: audio.toSec }
            : {}),
        });
        clip = await this.deps.editor.importMedia(clip);
        // Lip-sync post-pass when the video model can't do it inline.
        if (audio && !video.audioNative && this.deps.suite.lipSync) {
          this.updateShot(shot, { status: "lipsync" });
          const synced = await this.deps.suite.lipSync.sync({
            videoMediaId: clip,
            audioMediaId: audio.mediaId,
            fromSec: audio.fromSec,
            toSec: audio.toSec,
          });
          clip = await this.deps.editor.importMedia(synced);
          shot.lipSynced = true;
        }
        // The dailies check: a reviewer watches the take against the plan.
        // A declined take retries (the throw lands in the catch below, and the
        // retake prompt carries the note); the last attempt places regardless —
        // a weak take beats a frozen still. The chosen window trims the
        // placement to the take's best moment.
        let srcInSec: number | undefined;
        if (this.deps.suite.review) {
          this.updateShot(shot, { status: "reviewing" });
          const verdict = await this.reviewTake(clip, shot);
          if (!verdict.ok && attempt < VIDEO_ATTEMPTS) {
            critique = verdict.note?.trim() || "the take did not show the planned action";
            throw new Error(`Retake: ${critique}`);
          }
          srcInSec = verdict.fromSec;
        }
        // Swap the new clip in only now that it's ready, replacing any prior
        // placement (a resume's fallback still, a regen's old clip) atomically.
        await this.clearVideoPlacement(shot);
        shot.lastPrompt = prompt;
        shot.clip = clip;
        shot.timelineClipId = await this.deps.editor.placeClip(
          clip,
          shot.startFrame,
          shot.endFrame,
          srcInSec ? { srcInSec } : undefined
        );
        this.updateShot(shot, { status: "placed", error: undefined });
        this.emitProgress();
        return;
      } catch (e) {
        shot.error = String(e instanceof Error ? e.message : e);
        if (attempt < VIDEO_ATTEMPTS) await this.sleep(BACKOFF_MS * attempt);
      }
    }
    await this.placeFallback(shot); // never leave a hole
    this.emitProgress();
  }

  /** Watch a rendered take against its plan — best-effort: a reviewer outage
   * never blocks placement, it just goes unwatched. */
  private async reviewTake(clip: string, shot: Shot): Promise<ReviewVerdict> {
    try {
      return await this.deps.suite.review!.watch({
        videoMediaId: clip,
        action: shot.action,
        narration: (shot.dialogue ?? shot.audioText).trim(),
        slotSec: frameToSec(shotDurationFrames(shot), this.fps),
      });
    } catch {
      return { ok: true };
    }
  }

  /** The audio slice a shot should be spoken over. */
  private audioForShot(shot: Shot): { mediaId: string; fromSec: number; toSec: number } | undefined {
    if (this.project.audioMode === "generated") {
      if (!shot.voiceAssetId) return undefined;
      return {
        mediaId: shot.voiceAssetId,
        fromSec: shot.voiceFromSec ?? 0,
        toSec: shot.voiceToSec ?? frameToSec(shotDurationFrames(shot), this.fps),
      };
    }
    if (!this.project.audioAssetId) return undefined;
    return {
      mediaId: this.project.audioAssetId,
      fromSec: frameToSec(shot.startFrame, this.fps),
      toSec: frameToSec(shot.endFrame, this.fps),
    };
  }

  /** Hold a still for a shot whose video couldn't be made — never a black gap. */
  private async placeFallback(shot: Shot): Promise<void> {
    if (this.aborted) return; // a paused run neither spends nor places
    const still = await this.fallbackStill(shot);
    if (still) {
      await this.clearVideoPlacement(shot);
      // `still` is already an imported project media id; placing it directly
      // avoids re-importing an id the pool already holds.
      shot.clip = still;
      shot.timelineClipId = await this.deps.editor.placeClip(still, shot.startFrame, shot.endFrame);
    } else {
      // Nothing to hold — keep whatever was there rather than opening a hole.
      this.deps.emit({ type: "error", message: `Shot ${shot.id} could not be generated or filled.` });
    }
    this.updateShot(shot, { status: "failed" });
  }

  /** Source a still for a fallback: this shot's keyframe, a freshly minted one,
   * or a neighbor's frame — so a keyframe-gen failure never leaves a hole. */
  private async fallbackStill(shot: Shot): Promise<string | undefined> {
    if (shot.startKeyframe) return shot.startKeyframe;
    if (shot.endKeyframe) return shot.endKeyframe;
    try {
      shot.startKeyframe = await this.importedImage(`${buildPrompt(shot, this.project)} Still frame.`, shotRefs(shot, this.project));
      return shot.startKeyframe;
    } catch {
      /* fall through to holding a neighbor's frame */
    }
    const idx = this.project.shots.findIndex((s) => s.id === shot.id);
    for (let i = idx - 1; i >= 0; i--) {
      const prev = this.project.shots[i];
      if (prev.clip) return prev.clip;
      if (prev.startKeyframe) return prev.startKeyframe;
    }
    for (let i = idx + 1; i < this.project.shots.length; i++) {
      const next = this.project.shots[i];
      if (next.clip) return next.clip;
      if (next.startKeyframe) return next.startKeyframe;
    }
    return undefined;
  }

  private async clearVideoPlacement(shot: Shot): Promise<void> {
    if (shot.timelineClipId) {
      await this.deps.editor.removeClip(shot.timelineClipId);
      shot.timelineClipId = undefined;
    }
  }

  // ── Phase H: polish ──────────────────────────────────────────────────────
  private async polish(): Promise<void> {
    if (this.aborted) return;
    this.setPhase("polish");
    // Compose the bed now — after the gate and the shots — so an unapproved plan
    // never spends on one. Generated mode only: a provided audio spine is the
    // soundtrack, so nothing is laid over it. Best-effort: no music backend (or
    // one that declines) just means no bed.
    if (this.project.audioMode === "generated" && !this.project.musicAssetId && this.deps.suite.music) {
      try {
        this.deps.emit({ type: "activity", message: "Composing the music bed…" });
        const music = await this.deps.suite.music.compose({
          mood: this.project.script?.style ?? this.project.style ?? "cinematic underscore",
          durationSec: frameToSec(this.durationFrames, this.fps),
        });
        this.project.musicAssetId = await this.deps.editor.importMedia(music);
      } catch {
        this.deps.emit({ type: "log", message: "No music bed this time — assembling without one." });
      }
    }
    if (this.project.musicAssetId) {
      // Idempotent: replace the prior bed instead of stacking a second one.
      if (this.project.musicClipId) await this.deps.editor.removeAudio(this.project.musicClipId);
      this.project.musicClipId = await this.deps.editor.placeAudio(this.project.musicAssetId, 0, this.durationFrames, {
        kind: "music",
        lane: 1,
      });
    }
    const placed = this.project.shots.filter((s) => s.timelineClipId).length;
    const failed = this.project.shots.filter((s) => s.status === "failed").length;
    this.deps.emit({
      type: "log",
      message:
        `Video assembled with ${this.deps.suite.label}: ${placed}/${this.project.shots.length} shots on the track` +
        (failed ? `, ${failed} held as a still to regenerate.` : "."),
    });
    this.setPhase("done");
    await this.save();
  }

  // ── Selective regeneration (review loop + follow-up diffs) ───────────────

  async regenerateShots(ids: string[], mutate?: (shot: Shot) => void): Promise<VideoProject> {
    const targets: Shot[] = [];
    for (const id of ids) {
      const shot = this.project.shots.find((s) => s.id === id);
      if (!shot) continue;
      // Keep timelineClipId/clip so generateAndPlace swaps them once the new
      // clip is ready — clearing them up front would open a hole if the redo
      // fails. The beat voice is untouched, so narration never restacks.
      shot.startKeyframe = undefined;
      shot.endKeyframe = undefined;
      shot.lipSynced = false;
      shot.error = undefined;
      shot.status = "pending";
      mutate?.(shot);
      targets.push(shot);
    }
    await this.save();
    await fanOut(
      targets,
      async (shot) => {
        try {
          await this.makeKeyframes(shot);
        } catch {
          /* placeFallback will source a still */
        }
        await this.generateAndPlace(shot);
      },
      this.poolOpts(0)
    );
    await this.save();
    return this.project;
  }

  /** "Make shot N wider / a close-up" — a framing note, one shot dirtied. */
  async applyShotNote(id: string, note: string): Promise<VideoProject> {
    return this.regenerateShots([id], (shot) => {
      shot.action = shot.action ? `${shot.action} ${note}`.trim() : note;
    });
  }

  /** A style change dirties everything downstream of the style bible. */
  async changeStyle(style: string): Promise<VideoProject> {
    this.project.style = style;
    for (const a of [...this.project.characters, ...this.project.locations]) a.mediaId = undefined;
    await this.save();
    await this.style();
    await this.regenerateShots(this.project.shots.map((s) => s.id));
    // Restore the terminal phase so a later resume doesn't re-run polish (which
    // would otherwise re-place the music bed).
    this.setPhase("done");
    await this.save();
    return this.project;
  }

  shotIdByNumber(n: number): string | undefined {
    return this.project.shots[n - 1]?.id;
  }

  // ── helpers ──────────────────────────────────────────────────────────────

  private referencedAssets(): VideoAsset[] {
    const usedChars = new Set(this.project.shots.flatMap((s) => s.characters));
    const usedLocs = new Set(this.project.shots.map((s) => s.location));
    return [
      ...this.project.characters.filter((c) => usedChars.has(c.id)),
      ...this.project.locations.filter((l) => usedLocs.has(l.id)),
    ];
  }

  private async importedImage(prompt: string, refs: RefAsset[]): Promise<string> {
    const raw = await this.deps.suite.image.generate({ prompt, refs, aspect: this.aspect });
    return this.deps.editor.importMedia(raw);
  }

  private emitProgress(): void {
    const placed = this.project.shots.filter((s) => s.timelineClipId).length;
    this.deps.emit({ type: "progress", placed, total: this.project.shots.length });
  }

  private setPhase(phase: VideoPhase, note?: string): void {
    this.project.phase = phase;
    this.deps.emit({ type: "phase", phase, note });
  }

  private updateShot(shot: Shot, patch: Partial<Shot>): void {
    Object.assign(shot, patch);
    void this.save();
    this.deps.emit({ type: "shot:update", shot });
  }

  private poolOpts(retries: number) {
    return {
      concurrency: this.deps.concurrency ?? 6,
      retries,
      backoffMs: BACKOFF_MS,
      ...(this.deps.sleep ? { sleep: this.deps.sleep } : {}),
    };
  }

  private sleep(ms: number): Promise<void> {
    return this.deps.sleep ? this.deps.sleep(ms) : new Promise((r) => setTimeout(r, ms));
  }

  /** Persist, serialized so concurrent updates never interleave writes. An
   * aborted run stops persisting so it can't overwrite the plan the live run
   * (or a switched-to project) now owns. */
  private save(): Promise<void> {
    if (this.aborted) return Promise.resolve();
    this.project.updatedAt = this.project.updatedAt + 1; // monotonic without Date in tests
    this.saveChain = this.saveChain.then(() => this.deps.persist(this.project)).catch(() => {});
    return this.saveChain;
  }
}

/** Rough spoken length of a line for planning, before the real voiceover
 * exists — ~165 words/min, floored so even a couple of words hold a beat. */
function estimateSpokenSeconds(dialogue: string): number {
  const words = dialogue.trim().split(/\s+/).filter(Boolean).length;
  return Math.max(1.2, (words / 165) * 60);
}

/** Whether a shot has enough motion to warrant a distinct closing keyframe. */
function hasMotion(shot: Shot): boolean {
  return /\b(runs?|walks?|jumps?|flies|fly|turns?|moves?|falls?|rises?|spins?|races?|drives?|dances?|zoom)/i.test(
    shot.action
  );
}

/** Split one beat's span into contiguous shots each no longer than `maxFrames`,
 * distributing the remainder so the pieces stay as even as possible. */
function splitBeat(start: number, frames: number, maxFrames: number): [number, number][] {
  const parts = Math.max(1, Math.ceil(frames / maxFrames));
  const base = Math.floor(frames / parts);
  let rem = frames - base * parts;
  const out: [number, number][] = [];
  let s = start;
  for (let i = 0; i < parts; i++) {
    const size = base + (rem > 0 ? 1 : 0);
    if (rem > 0) rem--;
    const e = i === parts - 1 ? start + frames : s + size;
    out.push([s, e]);
    s = e;
  }
  return out;
}
