"use client";

/**
 * The real EditorBridge: the orchestrator's typed hands on the live Cut
 * timeline. It is the single frames↔seconds conversion boundary — the plan
 * reasons in whole frames at a fixed project rate, the editor store speaks
 * seconds, and every method here divides or multiplies by GEN_FPS exactly once.
 *
 * Placement forwards to the store's id-returning gen actions (placeGenClip /
 * placeGenAudio / removeClipById / removeAudioById), which place at an exact
 * time without sliding, mute generated shots, and never touch the user's
 * selection — so a run populates the track in the background while the user
 * keeps editing. `importMedia` is identity: the media adapters already import
 * their output into the project, so what they return is a real asset id.
 *
 * Every mutation is scoped to the run's own project: the store holds one open
 * project at a time, and a background run whose project the user has since
 * switched away from must never write to whatever project is now on screen. So
 * each method checks the open project first and no-ops (or throws, for the
 * id-returning placements) when it isn't this run's.
 */

import { useEditor } from "../store";
import type { TransitionStyle } from "../types";
import type { AudioClipInfo, EditorBridge, TimelineInfo } from "./editor";

/** The rate the plan runs at. Fixed to the export frame rate so a shot's frame
 * math lines up with the rendered file. */
export const GEN_FPS = 30;

const toSec = (frames: number) => frames / GEN_FPS;

/** Effective timeline footprint of a clip (seconds), honoring speed. */
function footprintSec(c: { in: number; out: number; speed?: number }): number {
  const src = c.out - c.in;
  return c.speed && c.speed > 0 ? src / c.speed : src;
}

export class StoreEditorBridge implements EditorBridge {
  constructor(private readonly projectId: string) {}

  /** Whether this run's project is the one currently open in the store. */
  private open(): boolean {
    return useEditor.getState().projectId === this.projectId;
  }

  getTimeline(): TimelineInfo {
    const s = useEditor.getState();
    const clipEnd = Math.max(
      0,
      ...s.clips.map((c) => c.start + footprintSec(c)),
      ...s.audioClips.map((c) => c.start + footprintSec(c))
    );
    return {
      fps: GEN_FPS,
      durationFrames: Math.round(clipEnd * GEN_FPS),
      aspect: s.aspect,
    };
  }

  getAudioClips(): AudioClipInfo[] {
    return useEditor.getState().audioClips.map((c) => ({
      clipId: c.id,
      assetId: c.assetId,
      startFrame: Math.round(c.start * GEN_FPS),
      durationFrames: Math.round(footprintSec(c) * GEN_FPS),
    }));
  }

  async importMedia(mediaId: string): Promise<string> {
    // The media adapters import their output before returning, so the id is
    // already a project asset id — nothing to do.
    return mediaId;
  }

  async placeClip(mediaId: string, startFrame: number, endFrame: number): Promise<string> {
    if (!this.open()) throw new Error("placeClip: run's project is no longer open");
    const id = useEditor.getState().placeGenClip(mediaId, toSec(startFrame), toSec(endFrame));
    if (!id) throw new Error(`placeClip: no placeable asset ${mediaId}`);
    return id;
  }

  async replaceClipMedia(clipId: string, mediaId: string): Promise<void> {
    if (!this.open()) return;
    useEditor.getState().updateClip(clipId, { assetId: mediaId });
  }

  async retimeClip(clipId: string, durationFrames: number): Promise<void> {
    if (!this.open()) return;
    const clip = useEditor.getState().clips.find((c) => c.id === clipId);
    if (!clip) return;
    // Trim the tail so the footprint matches, at whatever speed the clip carries.
    const speed = clip.speed && clip.speed > 0 ? clip.speed : 1;
    useEditor.getState().setClipTrim(clipId, clip.in, clip.in + toSec(durationFrames) * speed);
  }

  async removeClip(clipId: string): Promise<void> {
    if (!this.open()) return;
    useEditor.getState().removeClipById(clipId);
  }

  async addTransition(clipId: string, style: string, durationFrames: number): Promise<void> {
    if (!this.open()) return;
    useEditor.getState().setClipTransition(clipId, toSec(durationFrames), style as TransitionStyle);
  }

  async placeAudio(
    mediaId: string,
    startFrame: number,
    durationFrames: number,
    opts?: { kind?: "voice" | "music"; duck?: number; lane?: number }
  ): Promise<string> {
    if (!this.open()) throw new Error("placeAudio: run's project is no longer open");
    const id = useEditor
      .getState()
      .placeGenAudio(mediaId, toSec(startFrame), toSec(durationFrames), {
        ...(opts?.duck !== undefined ? { duck: opts.duck } : {}),
        ...(opts?.lane !== undefined ? { lane: opts.lane } : {}),
      });
    if (!id) throw new Error(`placeAudio: no audio asset ${mediaId}`);
    return id;
  }

  async removeAudio(clipId: string): Promise<void> {
    if (!this.open()) return;
    useEditor.getState().removeAudioById(clipId);
  }
}
