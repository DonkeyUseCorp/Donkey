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
 * - Cast identity is anchored per shot, strongest signal first (see the ladder
 *   in makeVideoRole): the shot's keyframe — already rendered with the cast's
 *   reference images, so it IS the cast — seeds an image-to-video render; if
 *   that's blocked, the character/location reference images condition a
 *   reference-to-video render; only as a last resort does a shot fall back to
 *   text-only, where the cast rides the prompt alone and drifts. The seeded
 *   and referenced modes run at personGeneration ALLOW_ADULT (the most Veo
 *   permits with image inputs); text-only runs ALLOW_ALL.
 * - Durations come from the video-model registry (videoGen.ts), never a literal
 *   here — models render only fixed clip lengths, so we ask for a supported one
 *   and let the editor trim it to the exact shot.
 */

import { refFromAsset, type AssetRef } from "../../assetRef";
import { tagChatAsset } from "../../chatAssets";
import { NO_CREDITS_MESSAGE, useGenerate, type VideoGenOptions } from "../../generate";
import { enrichAsset } from "../../media";
import { useEditor } from "../../store";
import { DEFAULT_VOICE, synthesizeSpeech } from "../../tts";
import { supportedVideoDuration, videoModel } from "../../videoGen";
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
      // The identity ladder: every rung renders the same prompt, each with a
      // weaker identity anchor, and a shot takes the first rung that lands.
      // Veo allows one anchor kind per render (seed OR references), caps both
      // at ALLOW_ADULT, and renders reference-conditioned clips at 8s only —
      // so the rungs are distinct requests, not one combined one.
      const base = {
        tier: VIDEO_TIER,
        aspect: input.aspect,
        // Chat ownership rides the job from creation, so a shot never touches
        // the Video panel — job row, tile, or badge — even when the render
        // errors or lands after the user moved on. Once placed on the timeline
        // it's protected from thread-deletion by the clip.
        ...(chatId ? { chatId } : {}),
      };
      const assets = useEditor.getState().assets;
      const keyframe = input.startKeyframe
        ? assets.find((a) => a.id === input.startKeyframe)
        : undefined;
      // Identity and place anchors only — a user style reference is a look,
      // not a cast member, and must never ride as an asset to keep consistent.
      const anchors = refsToAssetRefs(
        input.refs.filter((r) => r.purpose === "character" || r.purpose === "location")
      ).slice(0, videoModel(VIDEO_TIER).maxReferenceImages);
      const attempts: VideoGenOptions[] = [
        // 1. The keyframe as the literal first frame. It was rendered from the
        //    cast's reference images, so it carries identity, wardrobe, setting,
        //    and framing in one anchor — the strongest continuity Veo offers.
        ...(keyframe
          ? [{
              ...base,
              refs: [refFromAsset(keyframe)],
              composeRefs: false,
              personGeneration: "ALLOW_ADULT" as const,
              durationSeconds: supportedVideoDuration(VIDEO_TIER, input.durationSec),
            }]
          : []),
        // 2. Reference-to-video on the cast sheets themselves — identity holds,
        //    composition is the model's again.
        ...(anchors.length > 0
          ? [{
              ...base,
              referenceImages: anchors,
              personGeneration: "ALLOW_ADULT" as const,
              durationSeconds: supportedVideoDuration(VIDEO_TIER, input.durationSec, {
                withReferences: true,
              }),
            }]
          : []),
        // 3. Text-only, ALLOW_ALL — always renders, identity rides the prompt.
        {
          ...base,
          personGeneration: "ALLOW_ALL" as const,
          durationSeconds: supportedVideoDuration(VIDEO_TIER, input.durationSec),
        },
      ];
      let lastError = "Video generation failed.";
      for (const opts of attempts) {
        const job = await useGenerate.getState().generateVideo(projectId, input.prompt, opts)
          .settled;
        if (job.status === "done" && job.assetId) return job.assetId;
        lastError = job.error || lastError;
        // An empty balance fails every rung (and every orchestrator retry)
        // identically — stop here so a broke run fails fast, not 9 times.
        if (lastError === NO_CREDITS_MESSAGE) break;
      }
      throw new Error(lastError);
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
