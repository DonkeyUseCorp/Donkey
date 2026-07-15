"use client";

/**
 * The media roles — image, video, voice — over the exact browser-side
 * generation the panels and chat already use (`useGenerate`, `tts`). Each runs
 * on the user's Donkey session and credits and lands its output as a real
 * project asset, so what these return is a placeable asset id and the editor
 * bridge's `importMedia` has nothing left to do.
 *
 * Two shaping choices matter for the assembled cut:
 * - Video is NOT audio-native here: the model can't lip-sync our narration
 *   track, and every shot rides under a separate narration spine. We let the
 *   model generate whatever audio it wants and handle it locally — the placed
 *   clip is muted, so its audio never competes — rather than asking the model to
 *   suppress audio (a knob many models reject, which just fails the render).
 * - Shots render text-to-video with personGeneration ALLOW_ALL — no person-safety
 *   ceiling, so any character animates. That rules out a first-frame image seed
 *   (Veo caps a seeded render at ALLOW_ADULT and blocks faces it can't clear), so
 *   look continuity rides the prompt and style bible, not a keyframe.
 * - Durations come from the video-model registry (videoGen.ts), never a literal
 *   here — models render only fixed clip lengths, so we ask for a supported one
 *   and let the editor trim it to the exact shot.
 */

import { refFromAsset, type AssetRef } from "../../assetRef";
import { tagChatAsset } from "../../chatAssets";
import { useGenerate } from "../../generate";
import { enrichAsset } from "../../media";
import { useEditor } from "../../store";
import { DEFAULT_VOICE, synthesizeSpeech } from "../../tts";
import { supportedVideoDuration } from "../../videoGen";
import type { ImageRole, VideoRole, VoiceRole } from "../capabilities";
import type { RefAsset } from "../types";

/** Resolve the pipeline's media-id references to the project assets the
 * generators take, dropping any that are no longer in the project. */
function refsToAssetRefs(refs: RefAsset[]): AssetRef[] {
  const assets = useEditor.getState().assets;
  const out: AssetRef[] = [];
  for (const r of refs) {
    const a = assets.find((x) => x.id === r.mediaId);
    if (a) out.push(refFromAsset(a));
  }
  return out;
}

export function makeImageRole(projectId: string, chatId?: string): ImageRole {
  return {
    async generate(input) {
      const job = await useGenerate.getState().generateImage(projectId, input.prompt, {
        refs: refsToAssetRefs(input.refs),
        aspect: input.aspect,
        // The prompt is already complete (buildPrompt folds in style + setting);
        // the refs ride as identity anchors, not a prompt to rewrite.
        composeRefs: false,
        // Chat ownership rides the job from creation, so keyframes and reference
        // images never touch the Image panel — job row, tile, or badge — even
        // when the render errors or lands after the user moved on.
        ...(chatId ? { chatId } : {}),
      });
      if (job.status !== "done" || !job.assetId) {
        throw new Error(job.error || "Image generation failed.");
      }
      return job.assetId;
    },
  };
}

const VIDEO_TIER = "fast" as const;

export function makeVideoRole(projectId: string, chatId?: string): VideoRole {
  return {
    // The model isn't given our narration track, so it never lip-syncs to it.
    audioNative: false,
    async generate(input) {
      // Text-to-video with personGeneration ALLOW_ALL — no person-safety ceiling,
      // so any character animates (children included). That rules out a
      // first-frame image seed: Veo caps a seeded render at ALLOW_ADULT and
      // blocks a face it can't clear, which is what froze shots to a still. Look
      // continuity rides the prompt and the style bible instead of the keyframe.
      const job = await useGenerate.getState().generateVideo(projectId, input.prompt, {
        tier: VIDEO_TIER,
        // A length the model actually renders (registry-driven); the clip is
        // trimmed to the exact slot on placement.
        durationSeconds: supportedVideoDuration(VIDEO_TIER, input.durationSec),
        aspect: input.aspect,
        personGeneration: "ALLOW_ALL",
        // Chat ownership rides the job from creation, so a shot never touches
        // the Video panel — job row, tile, or badge — even when the render
        // errors or lands after the user moved on. Once placed on the timeline
        // it's protected from thread-deletion by the clip.
        ...(chatId ? { chatId } : {}),
      }).settled;
      if (job.status !== "done" || !job.assetId) {
        throw new Error(job.error || "Video generation failed.");
      }
      return job.assetId;
    },
  };
}

export function makeVoiceRole(projectId: string, chatId?: string): VoiceRole {
  return {
    async speak(input) {
      const { asset } = await synthesizeSpeech(projectId, [{ text: input.script, at: 0 }], {
        voice: input.voice || DEFAULT_VOICE,
        ...(input.direction ? { direction: input.direction } : {}),
        name: "Narration",
      });
      // synthesizeSpeech imports the file but leaves it to the caller to stock
      // the store, so the spine placement can find the asset. Only stock it when
      // this run's project is the one open — a background run whose project the
      // user switched away from must not add its narration to another project.
      if (useEditor.getState().projectId === projectId) {
        useEditor.getState().addAsset(asset);
        // Chat-owned, so the narration never shows in the Audio panel's
        // voiceover list — it's part of the run, placed on the soundtrack.
        // Only the run's own thread id: the ambient chat context is whatever
        // thread happens to be open when a background render lands.
        if (chatId) tagChatAsset(asset.id, chatId);
        void enrichAsset(asset);
      }
      return { mediaId: asset.id, durationSec: asset.duration };
    },
  };
}
