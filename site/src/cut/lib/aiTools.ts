"use client";

import { apiFetch, apiJson } from "./api";
import { refFromAsset, refFromStockVideo, type AssetRef } from "./assetRef";
import { chatOwner, tagChatAsset } from "./chatAssets";
import { useGenerate, type VideoGenOptions } from "./generate";
import { enrichAsset, ensurePeaks, importImage, importStockVideo } from "./media";
import { characterPrompt, stockTitle } from "./stock";
import { STOCK_IMAGES } from "./stockManifest";
import { STOCK_VIDEOS } from "./stockVideoManifest";
import { getClipSpans, nextFreeStart, TIMELINE_H_MAX, TIMELINE_H_MIN, totalDuration, useEditor } from "./store";
import { buildAiContext } from "./aiContext";
import { laneCues, subtitleLaneCount } from "./subtitles";
import { resolveVoice, synthesizeSpeech, SPEECH_VOICES } from "./tts";
import { DUCK_DEFAULT, generateSubtitlesReadout } from "./voiceover";
import {
  FRAME,
  IMAGE_CLIP_SECONDS,
  LAYOUTS,
  MAX_SUBTITLE_LANES,
  mediaUrl,
  rectOf,
  regionLabel,
  SPEED_MAX,
  SPEED_MIN,
  TRANSITION_STYLE_IDS,
  type AudioClip,
  type FontId,
  type MediaAsset,
  type OverlayClip,
  type TransitionStyle,
} from "./types";

const round2 = (n: number) => Math.round(n * 100) / 100;

const clamp = (v: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, v));
const isNum = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);

class ToolError extends Error {}

/**
 * Execute an assistant tool call against the live editor store.
 * Returns a small JSON-safe result; throws ToolError with a readable message.
 */
export async function runAiTool(
  name: string,
  input: Record<string, unknown>
): Promise<unknown> {
  const s = useEditor.getState();

  switch (name) {
    case "get_state":
      // The tool result carries the whole transcript; the per-message context
      // snapshot trims it, so this is how the model pulls every cue when needed.
      return buildAiContext({ fullCues: true });

    case "capture_frame": {
      const canvas = document.querySelector<HTMLCanvasElement>(".stage canvas");
      if (!canvas) throw new ToolError("No preview canvas on screen.");
      const scaled = document.createElement("canvas");
      // Downscale at the frame's own aspect (long side 640).
      const k = 640 / Math.max(canvas.width, canvas.height);
      scaled.width = Math.round(canvas.width * k);
      scaled.height = Math.round(canvas.height * k);
      const ctx = scaled.getContext("2d")!;
      ctx.drawImage(canvas, 0, 0, scaled.width, scaled.height);
      // Overlays/captions are DOM, not canvas — note that for the model.
      return { image: scaled.toDataURL("image/jpeg", 0.75), note: "Video frame only; titles and captions overlay this in the UI." };
    }

    case "seek": {
      if (!isNum(input.t)) throw new ToolError("t (seconds) is required.");
      s.seek(input.t);
      return { playhead: useEditor.getState().currentTime };
    }

    case "set_playing":
      s.setPlaying(Boolean(input.playing));
      return { playing: Boolean(input.playing) };

    case "select": {
      const kind = String(input.kind);
      if (kind === "none") {
        s.select(null);
        return { selection: null };
      }
      const id = String(input.id ?? "");
      const pool =
        kind === "clip"
          ? s.clips
          : kind === "overlayClip"
            ? s.overlayClips
            : kind === "audio"
              ? s.audioClips
              : kind === "text"
                ? s.overlays
                : null;
      if (!pool) throw new ToolError(`Unknown kind: ${kind}`);
      if (!pool.some((x) => x.id === id)) throw new ToolError(`No ${kind} with id ${id}.`);
      s.select({ kind: kind as "clip" | "overlayClip" | "audio" | "text", id });
      return { selection: { kind, id } };
    }

    case "split_at": {
      const before = s.clips.length + s.audioClips.length;
      s.splitAtPlayhead(isNum(input.t) ? input.t : undefined);
      const after = useEditor.getState();
      const made = after.clips.length + after.audioClips.length - before;
      if (made === 0) throw new ToolError("Nothing to split at that time.");
      return { split: true, videoClips: after.clips.length };
    }

    case "move_clip": {
      const clip = requireItem(s.clips, input.clipId, "video clip");
      if (!isNum(input.toIndex)) throw new ToolError("toIndex is required.");
      s.moveClip(clip.id, clamp(Math.round(input.toIndex), 0, s.clips.length - 1));
      return { order: useEditor.getState().clips.map((c) => c.id) };
    }

    case "place_clip": {
      const clip = requireItem(s.clips, input.clipId, "video clip");
      if (!isNum(input.start)) throw new ToolError("start (seconds) is required.");
      const len = (clip.out - clip.in) / (clip.speed && clip.speed > 0 ? clip.speed : 1);
      const taken = s.clips
        .filter((c) => c.id !== clip.id)
        .map((c) => ({
          start: c.start,
          end: c.start + (c.out - c.in) / (c.speed && c.speed > 0 ? c.speed : 1),
        }));
      const at = nextFreeStart(taken, Math.max(0, input.start), len);
      s.updateClip(clip.id, { start: at });
      useEditor.getState().sortClips();
      return {
        id: clip.id,
        start: round2(at),
        ...(Math.abs(at - Math.max(0, input.start)) > 0.005
          ? { note: "That spot was taken — slid right to the next free one." }
          : {}),
      };
    }

    case "add_overlay_video": {
      const asset = requireItem(s.assets, input.asset_id, "project asset");
      if (asset.type !== "video" && asset.type !== "image")
        throw new ToolError("Only video or image assets can sit on a video track.");
      const start = isNum(input.start) ? Math.max(0, input.start) : s.currentTime;
      const track = isNum(input.track) ? Math.round(input.track) : 1;
      if (track === 0) throw new ToolError("Track 0 holds the timeline clips — use place_clip for it.");
      s.addVideoFromAsset(asset.id, { kind: "track", track }, start);
      const cur = useEditor.getState();
      const sel = cur.selection;
      const id = sel?.kind === "overlayClip" ? sel.id : null;
      if (!id) throw new ToolError("Could not create the overlay clip.");
      // Same undo step as the add: the layout rides the transient patch.
      if (typeof input.layout === "string")
        cur.updateOverlayClipTransient(id, layoutPatch(input.layout));
      const c = useEditor.getState().overlayClips.find((x) => x.id === id)!;
      return {
        id: c.id,
        track: c.track,
        start: round2(c.start),
        len: round2((c.out - c.in) / (c.speed && c.speed > 0 ? c.speed : 1)),
        layout: regionLabel(rectOf(c)),
      };
    }

    case "update_overlay_video": {
      const c = requireItem(s.overlayClips, input.id, "overlay video clip");
      const asset = s.assets.find((a) => a.id === c.assetId);
      // A still has no source bound, so its clip can stretch to any length.
      const dur = asset?.type === "image" ? Infinity : asset?.duration ?? c.out;
      const patch: Partial<OverlayClip> = {};
      if (isNum(input.start)) patch.start = Math.max(0, input.start);
      if (isNum(input.in)) patch.in = clamp(input.in, 0, dur - 0.1);
      if (isNum(input.out)) patch.out = clamp(input.out, 0.1, dur);
      if (patch.in !== undefined || patch.out !== undefined) {
        if ((patch.out ?? c.out) - (patch.in ?? c.in) < 0.1)
          throw new ToolError("Clip must stay at least 0.1s long.");
      }
      if (isNum(input.track)) {
        const track = Math.round(input.track);
        if (track === 0) throw new ToolError("Track 0 holds the timeline clips — overlays are non-zero.");
        patch.track = track;
      }
      if (typeof input.muted === "boolean") patch.muted = input.muted;
      if (typeof input.hidden === "boolean") patch.hidden = input.hidden || undefined;
      if (typeof input.layout === "string") {
        Object.assign(patch, layoutPatch(input.layout));
      } else if (input.region && typeof input.region === "object") {
        const rg = input.region as Record<string, unknown>;
        if (!isNum(rg.x) || !isNum(rg.y) || !isNum(rg.w) || !isNum(rg.h))
          throw new ToolError("region needs numeric x, y, w, h (frame fractions).");
        const w = clamp(rg.w, 0.05, 1);
        const h = clamp(rg.h, 0.05, 1);
        patch.frame = { x: clamp(rg.x, 0, 1 - w), y: clamp(rg.y, 0, 1 - h), w, h };
      }
      if (input.fit === "fit" || input.fit === "fill") patch.fit = input.fit;
      if (isNum(input.speed)) patch.speed = clamp(input.speed, SPEED_MIN, SPEED_MAX);
      if (Object.keys(patch).length === 0) throw new ToolError("Nothing to change.");
      s.updateOverlayClip(c.id, patch);
      const next = useEditor.getState().overlayClips.find((x) => x.id === c.id)!;
      return {
        id: next.id,
        track: next.track,
        start: round2(next.start),
        layout: regionLabel(rectOf(next)),
        fit: next.fit ?? "fit",
        muted: next.muted,
        ...(next.hidden ? { hidden: true } : {}),
      };
    }

    case "trim_clip": {
      const clip = requireItem(s.clips, input.clipId, "video clip");
      const asset = s.assets.find((a) => a.id === clip.assetId);
      // A still has no source bound, so its clip can stretch to any length.
      const dur = asset?.type === "image" ? Infinity : asset?.duration ?? clip.out;
      const nextIn = isNum(input.in) ? clamp(input.in, 0, dur - 0.1) : clip.in;
      const nextOut = isNum(input.out) ? clamp(input.out, 0.1, dur) : clip.out;
      if (nextOut - nextIn < 0.1) throw new ToolError("Clip must stay at least 0.1s long.");
      s.updateClip(clip.id, { in: nextIn, out: nextOut });
      return { in: nextIn, out: nextOut, len: Math.round((nextOut - nextIn) * 100) / 100 };
    }

    case "set_clip_muted": {
      const clip = requireItem(s.clips, input.clipId, "video clip");
      s.updateClip(clip.id, { muted: Boolean(input.muted) });
      return { muted: Boolean(input.muted) };
    }

    case "detach_audio": {
      const id = input.clipId ? String(input.clipId) : s.selection?.kind === "clip" ? s.selection.id : null;
      if (!id) throw new ToolError("Pass clipId or select a video clip first.");
      const clip = requireItem(s.clips, id, "video clip");
      if (clip.muted) throw new ToolError("That clip's audio is muted — nothing to detach.");
      s.select({ kind: "clip", id: clip.id });
      s.detachAudio();
      const asset = s.assets.find((a) => a.id === clip.assetId);
      if (asset) void ensurePeaks(asset);
      const sel = useEditor.getState().selection;
      return { audioClipId: sel?.kind === "audio" ? sel.id : null };
    }

    case "delete_item": {
      const kind = String(input.kind) as "clip" | "overlayClip" | "audio" | "text";
      const id = String(input.id ?? "");
      const pool =
        kind === "clip"
          ? s.clips
          : kind === "overlayClip"
            ? s.overlayClips
            : kind === "audio"
              ? s.audioClips
              : s.overlays;
      if (!pool.some((x) => x.id === id)) throw new ToolError(`No ${kind} with id ${id}.`);
      s.select({ kind, id });
      s.deleteSelection();
      return { deleted: { kind, id } };
    }

    case "add_title": {
      if (typeof input.text !== "string" || !input.text.trim())
        throw new ToolError("text is required.");
      if (isNum(input.start)) s.seek(input.start);
      s.addOverlay();
      const cur = useEditor.getState();
      const sel = cur.selection;
      if (sel?.kind !== "text") throw new ToolError("Could not create the title.");
      cur.updateOverlayTransient(sel.id, titlePatch({ ...input, id: sel.id }));
      const o = useEditor.getState().overlays.find((x) => x.id === sel.id)!;
      return { id: o.id, text: o.text, start: o.start, end: o.end };
    }

    case "update_title": {
      const o = requireItem(s.overlays, input.id, "title");
      s.updateOverlay(o.id, titlePatch(input));
      const next = useEditor.getState().overlays.find((x) => x.id === o.id)!;
      return { id: next.id, text: next.text, color: next.color, size: next.size };
    }

    case "update_audio": {
      const a = requireItem(s.audioClips, input.id, "soundtrack clip");
      const aSpeed = a.speed && a.speed > 0 ? a.speed : 1;
      const len = (a.out - a.in) / aSpeed;
      const patch: Partial<AudioClip> = {};
      if (isNum(input.volume)) patch.volume = clamp(input.volume, 0, 1.5);
      if (isNum(input.fadeIn)) patch.fadeIn = clamp(input.fadeIn, 0, len / 2);
      if (isNum(input.fadeOut)) patch.fadeOut = clamp(input.fadeOut, 0, len / 2);
      if (isNum(input.start)) patch.start = Math.max(0, input.start);
      if (isNum(input.in)) patch.in = Math.max(0, input.in);
      if (isNum(input.out)) patch.out = input.out;
      // duck >= 1 clears ducking (undefined); below 1 sets the gain.
      if (isNum(input.duck)) patch.duck = input.duck >= 1 ? undefined : clamp(input.duck, 0, 1);
      if (isNum(patch.in ?? NaN) || isNum(patch.out ?? NaN)) {
        const nIn = patch.in ?? a.in;
        const nOut = patch.out ?? a.out;
        if (nOut - nIn < 0.1) throw new ToolError("Audio clip must stay at least 0.1s long.");
      }
      if (!("duck" in patch) && Object.keys(patch).length === 0)
        throw new ToolError("Nothing to change.");
      s.updateAudio(a.id, patch);
      return { id: a.id, ...patch };
    }

    case "set_framing": {
      const clip = requireItem(s.clips, input.clipId, "video clip");
      const mode = input.mode === "fill" ? "fill" : "fit";
      s.updateClip(clip.id, {
        fit: mode,
        panX: mode === "fill" && isNum(input.panX) ? clamp(input.panX, -1, 1) : 0,
        panY: mode === "fill" && isNum(input.panY) ? clamp(input.panY, -1, 1) : 0,
      });
      const next = useEditor.getState().clips.find((c) => c.id === clip.id)!;
      return { id: next.id, fit: next.fit, panX: next.panX ?? 0, panY: next.panY ?? 0 };
    }

    case "freeze_frame": {
      const projectId = s.projectId;
      if (!projectId) throw new ToolError("No project open.");
      const spans = getClipSpans(s.clips, s.assets);
      if (spans.length === 0) throw new ToolError("The timeline is empty.");
      const total = totalDuration(s.clips);
      const t = clamp(isNum(input.t) ? input.t : s.currentTime, 0, Math.max(0, total - 0.001));
      const span = spans.find((sp) => t >= sp.start && t < sp.start + sp.len) ?? spans[spans.length - 1];
      const srcTime = span.clip.in + (t - span.start);
      const res = await apiFetch(`/api/cut/projects/${projectId}/freeze`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          file: span.asset.fileName,
          srcTime,
          duration: isNum(input.duration) ? input.duration : 1,
          // Bake the still at the current project frame, framed exactly as
          // the preview shows it. Switching aspect later letterboxes this
          // still — capture a fresh one to re-fit.
          frame: { w: FRAME[s.aspect].w, h: FRAME[s.aspect].h },
          framing: {
            fit: span.clip.fit ?? "fit",
            panX: span.clip.panX ?? 0,
            panY: span.clip.panY ?? 0,
          },
        }),
      });
      const body = await apiJson<MediaAsset>(res);
      if (!res.ok) throw new ToolError(body.error ?? "Could not render the freeze frame.");
      const asset: MediaAsset = { ...body, url: mediaUrl(projectId, body.fileName), origin: "freeze" };
      const cur = useEditor.getState();
      cur.addAsset(asset);
      cur.addClipFromAsset(asset.id); // lands at the end, selected
      const sel = useEditor.getState().selection;
      const index = clamp(isNum(input.index) ? Math.round(input.index) : 0, 0, useEditor.getState().clips.length - 1);
      if (sel?.kind === "clip") cur.moveClip(sel.id, index);
      void enrichAsset(asset);
      return {
        assetId: asset.id,
        clipId: sel?.kind === "clip" ? sel.id : null,
        index,
        duration: body.duration,
        from: { time: Math.round(t * 100) / 100, source: span.asset.name },
      };
    }

    case "generate_image": {
      const projectId = s.projectId;
      if (!projectId) throw new ToolError("No project open.");
      const prompt = String(input.prompt ?? "").trim();
      if (!prompt) throw new ToolError("A prompt is required.");
      const refs = resolveRefAssets(input.reference_asset_ids);

      // Captured before the render: the image files under the chat that
      // asked, even if the user switches threads while it generates.
      const chatId = chatOwner();
      // Hosted image generation is synchronous and quick, so wait it out.
      const job = await useGenerate.getState().generateImage(projectId, prompt, {
        ...(input.aspect === "16:9" || input.aspect === "9:16" || input.aspect === "1:1"
          ? { aspect: input.aspect }
          : {}),
        ...(input.resolution === "1K" || input.resolution === "2K" || input.resolution === "4K"
          ? { resolution: input.resolution }
          : {}),
        ...(refs.length > 0 ? { refs } : {}),
      });
      if (job.status !== "done" || !job.assetId) {
        throw new ToolError(job.error ?? "Image generation failed.");
      }
      const cur = useEditor.getState();
      const asset = cur.assets.find((a) => a.id === job.assetId);
      if (!asset) throw new ToolError("The generated image did not land in the project.");
      tagChatAsset(asset.id, chatId);
      const placed = wantsTimeline(input, "index")
        ? addGeneratedClip(asset.id, promptedIndex(input))
        : NOT_PLACED;
      return {
        assetId: asset.id,
        name: asset.name,
        kind: "image",
        // A still has no source length; report its default placed length.
        duration: IMAGE_CLIP_SECONDS,
        addedToTimeline: placed.added,
        clipId: placed.clipId,
        index: placed.index,
      };
    }

    case "generate_video": {
      const projectId = s.projectId;
      if (!projectId) throw new ToolError("No project open.");
      const prompt = String(input.prompt ?? "").trim();
      if (!prompt) throw new ToolError("A prompt is required.");
      const gen = useGenerate.getState();
      // The render is fire-and-forget below, so a signed-out user must be
      // caught here — an unprobed session (null) resolves before we claim
      // success. Deeper errors surface in the panel's job list.
      const signedIn = gen.signedIn ?? (await gen.probeNow());
      if (!signedIn) throw new ToolError("Sign in to Donkey to generate video.");

      // Veo renders can outrun the assistant tool bridge's 2-minute cap, so
      // don't block: start the job and let its completion place the clip.
      const refs =
        input.reference_asset_id === undefined
          ? []
          : resolveRefAssets([input.reference_asset_id]);
      return launchVeoJob(projectId, prompt, input, {
        tier: input.tier === "high" ? "high" : "fast",
        durationSeconds: isNum(input.duration_seconds)
          ? clamp(Math.round(input.duration_seconds), 4, 8)
          : undefined,
        ...(input.aspect === "16:9" || input.aspect === "9:16" ? { aspect: input.aspect } : {}),
        ...(input.resolution === "720p" || input.resolution === "1080p"
          ? { resolution: input.resolution }
          : {}),
        ...(refs.length > 0 ? { refs } : {}),
      });
    }

    case "generate_character_video": {
      const projectId = s.projectId;
      if (!projectId) throw new ToolError("No project open.");
      const id = String(input.character_id ?? "");
      const character = STOCK_VIDEOS.find((v) => v.id === id && v.persona);
      if (!character)
        throw new ToolError(`No talking character with id ${id}. Call stock_search kind:"character".`);
      const line = String(input.line ?? "").trim();
      if (!line) throw new ToolError("line is required — what should they say?");
      const gen = useGenerate.getState();
      const signedIn = gen.signedIn ?? (await gen.probeNow());
      if (!signedIn) throw new ToolError("Sign in to Donkey to generate video.");
      return {
        ...launchVeoJob(projectId, characterPrompt(character.persona!, line), input, {
          tier: input.tier === "high" ? "high" : "fast",
          durationSeconds: isNum(input.duration_seconds)
            ? clamp(Math.round(input.duration_seconds), 4, 8)
            : undefined,
          aspect: character.aspect,
          // The character's own clip seeds the render so the same person
          // delivers the line — composing would swap the face, so it rides raw.
          refs: [refFromStockVideo(character)],
          composeRefs: false,
        }),
        character: character.id,
      };
    }

    case "stock_search": {
      const q = String(input.query ?? "").trim().toLowerCase();
      const kindIn =
        input.kind === "video" || input.kind === "image" || input.kind === "character"
          ? input.kind
          : undefined;
      interface Hit {
        id: string;
        kind: "video" | "image" | "character";
        category: string;
        aspect: string;
        duration?: number;
        persona?: string;
        prompt: string;
        tags: string[];
      }
      const hits: Hit[] = [];
      for (const v of STOCK_VIDEOS) {
        const kind = v.category === "Characters" ? "character" : "video";
        if (kindIn && kindIn !== kind) continue;
        hits.push({
          id: v.id,
          kind,
          category: v.category,
          aspect: v.aspect,
          duration: round2(v.duration),
          ...(v.persona ? { persona: v.persona } : {}),
          prompt: v.prompt,
          tags: v.tags,
        });
      }
      if (!kindIn || kindIn === "image") {
        for (const i of STOCK_IMAGES) {
          hits.push({
            id: i.id,
            kind: "image",
            category: i.category,
            aspect: i.aspect,
            prompt: i.prompt,
            tags: i.tags,
          });
        }
      }
      const words = q.split(/\s+/).filter(Boolean);
      const matches = hits.filter((h) => {
        const hay = [h.id, h.category, h.prompt, h.persona ?? "", ...h.tags]
          .join(" ")
          .toLowerCase();
        return words.every((w) => hay.includes(w));
      });
      const trim = (t: string, n: number) => (t.length > n ? `${t.slice(0, n - 1)}…` : t);
      return {
        results: matches.slice(0, 12).map((h) => ({
          ...h,
          prompt: trim(h.prompt, 160),
          ...(h.persona ? { persona: trim(h.persona, 160) } : {}),
          tags: h.tags.slice(0, 6),
        })),
        total: matches.length,
        ...(matches.length > 12 ? { truncated: true } : {}),
      };
    }

    case "stock_add": {
      const projectId = s.projectId;
      if (!projectId) throw new ToolError("No project open.");
      const id = String(input.id ?? "");
      const vid = STOCK_VIDEOS.find((v) => v.id === id);
      const img = vid ? undefined : STOCK_IMAGES.find((i) => i.id === id);
      if (!vid && !img)
        throw new ToolError(`No stock item with id ${id}. Call stock_search for ids.`);
      // Captured before the import: the media files under the chat that
      // asked, even if the user switches threads while it downloads.
      const chatId = chatOwner();
      const asset = vid
        ? await importStockVideo(projectId, { url: vid.file, name: stockTitle(vid.id) })
        : await importImage(projectId, { url: img!.file, name: stockTitle(img!.id) });
      tagChatAsset(asset.id, chatId);
      const addToTimeline = wantsTimeline(input, "start");
      let clipId: string | null = null;
      if (addToTimeline) {
        useEditor
          .getState()
          .addClipFromAsset(asset.id, isNum(input.start) ? Math.max(0, input.start) : undefined);
        const sel = useEditor.getState().selection;
        clipId = sel?.kind === "clip" ? sel.id : null;
      }
      return {
        assetId: asset.id,
        name: asset.name,
        kind: vid ? "video" : "image",
        duration: round2(vid ? asset.duration : IMAGE_CLIP_SECONDS),
        addedToTimeline: addToTimeline,
        clipId,
      };
    }

    case "subtitles_generate": {
      const lane = targetSubtitleTrack(input);
      if (typeof input.locale === "string" && input.locale)
        useEditor.getState().setSubtitleTrackMeta(lane, { locale: input.locale });
      await useEditor.getState().generateSubtitles();
      const cur = useEditor.getState();
      if (cur.subtitleStatus === "error")
        throw new ToolError(cur.subtitleError ?? "Transcription failed.");
      const made = laneCues(cur.subtitles, lane).length;
      if (made > 0 && cur.timelineH < 276) cur.setTimelineH(276);
      return {
        status: cur.subtitleStatus,
        track: lane,
        cues: made,
        note:
          cur.subtitleStatus === "empty"
            ? "No speech found — no subtitles were added to the video."
            : undefined,
      };
    }

    case "captions_generate": {
      const raw = typeof input.style === "string" ? input.style : "hook";
      const style = (["clean", "hook", "punchy"].includes(raw) ? raw : "hook") as
        | "clean"
        | "hook"
        | "punchy";
      const lane = targetSubtitleTrack(input);
      await useEditor.getState().generateCaptions(style);
      const cur = useEditor.getState();
      if (cur.subtitleStatus === "error")
        throw new ToolError(cur.subtitleError ?? "Captions failed.");
      const made = laneCues(cur.subtitles, lane).length;
      if (made > 0 && cur.timelineH < 276) cur.setTimelineH(276);
      return {
        status: cur.subtitleStatus,
        track: lane,
        cues: made,
        style: cur.subtitles.style,
        note:
          cur.subtitleStatus === "empty"
            ? "No speech found — no captions were added to the video."
            : undefined,
      };
    }

    case "subtitles_from_visuals": {
      const lane = targetSubtitleTrack(input);
      if (typeof input.locale === "string" && input.locale)
        useEditor.getState().setSubtitleTrackMeta(lane, { locale: input.locale });
      await useEditor.getState().generateVisualSubtitles();
      const cur = useEditor.getState();
      if (cur.subtitleStatus === "error")
        throw new ToolError(cur.subtitleError ?? "Visual captioning failed.");
      const made = laneCues(cur.subtitles, lane).length;
      if (made > 0 && cur.timelineH < 276) cur.setTimelineH(276);
      return { status: cur.subtitleStatus, track: lane, cues: made };
    }

    case "subtitles_add_track": {
      const count = subtitleLaneCount(s.subtitles);
      if (count >= MAX_SUBTITLE_LANES)
        throw new ToolError(`Already at ${MAX_SUBTITLE_LANES} subtitle tracks.`);
      s.addSubtitleTrack(
        typeof input.language === "string" && input.language.trim()
          ? input.language.trim()
          : undefined
      );
      return { track: count, tracks: count + 1 };
    }

    case "subtitles_remove_track": {
      if (!isNum(input.track)) throw new ToolError("track is required.");
      const lane = Math.round(input.track);
      const count = subtitleLaneCount(s.subtitles);
      if (lane < 0 || lane >= count) throw new ToolError(`No subtitle track ${lane}.`);
      if (count <= 1) throw new ToolError("The last subtitle track can't be removed.");
      s.removeSubtitleTrack(lane);
      return { removed: lane, tracks: count - 1 };
    }

    case "subtitles_translate_track": {
      const language = typeof input.language === "string" ? input.language.trim() : "";
      if (!language) throw new ToolError("language (BCP-47, e.g. ko-KR) is required.");
      const subs = s.subtitles;
      const count = subtitleLaneCount(subs);
      const localeOf = (i: number) =>
        subs.tracks?.[i]?.locale ?? (i === 0 ? subs.locale : undefined);
      const hasCues = (i: number) => laneCues(subs, i).length > 0;
      const lanes = Array.from({ length: count }, (_, i) => i);
      const from = isNum(input.from_track)
        ? Math.round(input.from_track)
        : lanes.find(hasCues) ?? -1;
      if (from < 0 || from >= count || !hasCues(from))
        throw new ToolError("No captions to translate — generate subtitles first.");
      // Reuse the track already set to this language, else add one.
      let target = lanes.find((i) => i !== from && localeOf(i) === language) ?? -1;
      if (target < 0) {
        if (count >= MAX_SUBTITLE_LANES)
          throw new ToolError(
            `Already at ${MAX_SUBTITLE_LANES} subtitle tracks — remove one first.`
          );
        s.addSubtitleTrack(language);
        target = count;
      }
      const st = useEditor.getState();
      st.setSubtitleLane(target);
      st.setSubtitleTrackMeta(target, { locale: language });
      await useEditor.getState().translateSubtitleTrack(from);
      const cur = useEditor.getState();
      if (cur.subtitleStatus === "error")
        throw new ToolError(cur.subtitleError ?? "Translation failed.");
      if (cur.timelineH < 276) cur.setTimelineH(276);
      return {
        track: target,
        language,
        from,
        cues: laneCues(cur.subtitles, target).length,
      };
    }

    case "list_voices": {
      // Gemini's prebuilt voice catalog is fixed and ships hardcoded.
      return {
        voices: SPEECH_VOICES.map((v) => ({ id: v.id, style: v.style })),
        total: SPEECH_VOICES.length,
      };
    }

    case "voiceover_generate": {
      if (typeof input.script !== "string" || !input.script.trim())
        throw new ToolError("script is required.");
      const start = isNum(input.start) ? Math.max(0, input.start) : s.currentTime;
      const lead = input.script.trim().split(/\s+/).slice(0, 4).join(" ");
      const place = wantsTimeline(input, "start");
      return synthesizeVoiceover(
        [{ text: input.script, at: 0 }],
        `AI voice — ${lead}`,
        start,
        input,
        place
      );
    }

    case "read_subtitles_aloud": {
      const lane = targetSubtitleTrack(input);
      if (!laneCues(useEditor.getState().subtitles, lane).some((c) => c.text.trim()))
        throw new ToolError("No subtitles on that track — generate subtitles first.");
      const voice = resolveVoice(typeof input.voice === "string" ? input.voice : undefined);
      // The shared readout also re-times the cues to the generated voice's
      // pace, keeping the word highlighter in step.
      const out = await generateSubtitlesReadout(voice, {
        direction:
          typeof input.direction === "string" && input.direction.trim()
            ? input.direction.trim()
            : undefined,
        language: typeof input.language === "string" ? input.language : undefined,
        duck: isNum(input.duck) ? clamp(input.duck, 0, 1) : undefined,
      });
      const sel = useEditor.getState().selection;
      return {
        assetId: out.asset.id,
        name: out.asset.name,
        audioClipId: sel?.kind === "audio" ? sel.id : null,
        voice,
        start: round2(out.start),
        duration: round2(out.asset.duration),
        duck: out.duck,
        lines: out.lines,
      };
    }

    case "subtitles_set_view": {
      const patch: { showOnVideo?: boolean; showOnTimeline?: boolean } = {};
      if (typeof input.showOnVideo === "boolean") patch.showOnVideo = input.showOnVideo;
      if (typeof input.showOnTimeline === "boolean") patch.showOnTimeline = input.showOnTimeline;
      s.setSubtitlesView(patch);
      if (patch.showOnTimeline && s.subtitles.cues.length > 0 && s.timelineH < 276) s.setTimelineH(276);
      return patch;
    }

    case "update_cue": {
      const cue = requireItem(s.subtitles.cues, input.id, "subtitle cue");
      if (typeof input.text === "string") s.setCueText(cue.id, input.text);
      if (isNum(input.start) || isNum(input.end)) {
        const start = isNum(input.start) ? Math.max(0, input.start) : cue.start;
        const end = isNum(input.end) ? input.end : cue.end;
        if (end - start < 0.15) throw new ToolError("Cue must stay at least 0.15s long.");
        s.pushHistory();
        s.updateCueTransient(cue.id, { start, end, words: undefined });
        s.sortCues();
      }
      const next = useEditor.getState().subtitles.cues.find((c) => c.id === cue.id);
      return next ? { id: next.id, start: next.start, end: next.end, text: next.text } : { deleted: cue.id };
    }

    case "delete_cue": {
      const cue = requireItem(s.subtitles.cues, input.id, "subtitle cue");
      s.deleteCue(cue.id);
      return { deleted: cue.id };
    }

    case "set_publish": {
      const patch: Record<string, string> = {};
      for (const k of ["caption", "tags", "soundTitle", "handle"] as const) {
        if (typeof input[k] === "string") patch[k] = input[k] as string;
      }
      if (Object.keys(patch).length === 0) throw new ToolError("Nothing to change.");
      s.setPublish(patch);
      return patch;
    }

    case "set_view": {
      const out: Record<string, number> = {};
      if (input.fit) {
        const el = document.querySelector<HTMLElement>(".tl-scroll");
        const dur = totalDuration(s.clips);
        if (el && dur > 0) {
          s.setPxPerSec((el.clientWidth - 60) / dur);
          el.scrollLeft = 0;
        }
        out.pxPerSec = useEditor.getState().pxPerSec;
      } else if (isNum(input.pxPerSec)) {
        s.setPxPerSec(input.pxPerSec);
        out.pxPerSec = useEditor.getState().pxPerSec;
      }
      if (isNum(input.timelineH)) {
        s.setTimelineH(clamp(input.timelineH, TIMELINE_H_MIN, TIMELINE_H_MAX));
        out.timelineH = useEditor.getState().timelineH;
      }
      return out;
    }

    case "undo":
      s.undo();
      return { ok: true };
    case "redo":
      s.redo();
      return { ok: true };

    case "open_export": {
      if (getClipSpans(s.clips, s.assets).length === 0)
        throw new ToolError("Add a video to the timeline first.");
      s.setExportOpen(true);
      return { open: true };
    }

    case "set_speed": {
      const clip = requireItem(s.clips, input.clipId, "video clip");
      if (!isNum(input.speed)) throw new ToolError("speed is required (0.25–4).");
      s.setClipSpeed(clip.id, input.speed);
      const next = useEditor.getState().clips.find((c) => c.id === clip.id)!;
      return { id: next.id, speed: next.speed ?? 1 };
    }

    case "set_transition": {
      const clip = requireItem(s.clips, input.clipId, "video clip");
      if (s.clips.findIndex((c) => c.id === clip.id) === s.clips.length - 1)
        throw new ToolError("The last clip has no next clip to transition into.");
      if (!isNum(input.seconds)) throw new ToolError("seconds is required (0 clears the transition).");
      let style: TransitionStyle | undefined;
      if (input.style !== undefined) {
        style = TRANSITION_STYLE_IDS.find((x) => x === input.style);
        if (!style) throw new ToolError(`Unknown style. Use one of: ${TRANSITION_STYLE_IDS.join(", ")}.`);
      }
      s.setClipTransition(clip.id, input.seconds, style);
      const next = useEditor.getState().clips.find((c) => c.id === clip.id)!;
      return { id: next.id, transition: next.transition ?? 0, style: next.transitionStyle ?? "crossfade" };
    }

    case "merge_cue": {
      const cue = requireItem(s.subtitles.cues, input.id, "subtitle cue");
      const mates = laneCues(s.subtitles, cue.lane ?? 0);
      if (mates.findIndex((c) => c.id === cue.id) <= 0)
        throw new ToolError("That is its track's first cue — nothing before it to merge into.");
      s.mergeCueIntoPrev(cue.id);
      return { mergedInto: "previous cue" };
    }

    case "set_aspect": {
      const a = input.aspect === "16:9" ? "16:9" : input.aspect === "9:16" ? "9:16" : null;
      if (!a) throw new ToolError('aspect must be "9:16" or "16:9".');
      s.setAspect(a);
      return { aspect: a };
    }

    case "set_project_fade": {
      if (!isNum(input.fadeIn) && !isNum(input.fadeOut))
        throw new ToolError("Pass fadeIn and/or fadeOut seconds (0 clears).");
      s.setProjectFade({
        ...(isNum(input.fadeIn) ? { fadeIn: input.fadeIn } : {}),
        ...(isNum(input.fadeOut) ? { fadeOut: input.fadeOut } : {}),
      });
      const after = useEditor.getState();
      return { fadeIn: after.fadeIn, fadeOut: after.fadeOut };
    }

    case "set_project_name": {
      if (typeof input.name !== "string" || !input.name.trim())
        throw new ToolError("name is required.");
      s.setProjectName(input.name.trim());
      return { name: input.name.trim() };
    }

    default:
      throw new ToolError(`Unknown tool: ${name}`);
  }
}

/** Synthesize speech segments with hosted Gemini voices (the user's Donkey
 * sign-in and credits), register the media, and drop one soundtrack clip
 * (voiceovers duck other audio by default). Shared by voiceover_generate and
 * read_subtitles_aloud. */
async function synthesizeVoiceover(
  segments: { text: string; at: number }[],
  name: string,
  start: number,
  input: Record<string, unknown>,
  place: boolean
) {
  const projectId = useEditor.getState().projectId;
  if (!projectId) throw new ToolError("No project open.");
  const voice = resolveVoice(typeof input.voice === "string" ? input.voice : undefined);
  const direction =
    typeof input.direction === "string" && input.direction.trim()
      ? input.direction.trim()
      : undefined;
  const duck = isNum(input.duck) ? clamp(input.duck, 0, 1) : DUCK_DEFAULT;
  // Captured before synthesis: the audio files under the chat that asked,
  // even if the user switches threads while it renders.
  const chatId = chatOwner();
  const { asset, offset } = await synthesizeSpeech(projectId, segments, {
    voice,
    direction,
    language: typeof input.language === "string" ? input.language : undefined,
    name,
  });
  const cur = useEditor.getState();
  cur.addAsset(asset);
  tagChatAsset(asset.id, chatId);
  void enrichAsset(asset);
  if (!place) {
    return {
      assetId: asset.id,
      name: asset.name,
      voice,
      duration: round2(asset.duration),
      addedToTimeline: false,
      note: "The voiceover previews in this chat — the user can play it and drag it onto the soundtrack; pass add_to_timeline or start when they ask for it in the cut.",
    };
  }
  // A single script lands at `start`; a multi-line readout is pre-offset to its
  // first cue, so it lands at that offset.
  const at = segments.length === 1 ? start : offset;
  cur.addAudioFromAsset(asset.id, at, { duck: duck < 1 ? duck : undefined });
  const sel = useEditor.getState().selection;
  return {
    assetId: asset.id,
    name: asset.name,
    audioClipId: sel?.kind === "audio" ? sel.id : null,
    voice,
    start: round2(at),
    duration: round2(asset.duration),
    duck: duck < 1 ? duck : null,
    addedToTimeline: true,
  };
}

function requireItem<T extends { id: string }>(pool: T[], id: unknown, label: string): T {
  const item = pool.find((x) => x.id === String(id ?? ""));
  if (!item) throw new ToolError(`No ${label} with id ${String(id)}. Call get_state for current ids.`);
  return item;
}

/** Resolve a subtitle-track tool param (default: the active track), make it
 * the active track — generation, translation, and readout all write there. */
function targetSubtitleTrack(input: Record<string, unknown>): number {
  const s = useEditor.getState();
  const count = subtitleLaneCount(s.subtitles);
  const lane = isNum(input.track) ? Math.round(input.track) : s.subtitleLane;
  if (lane < 0 || lane >= count)
    throw new ToolError(
      `No subtitle track ${lane} — tracks 0–${count - 1} exist (subtitles_add_track adds one).`
    );
  s.setSubtitleLane(lane);
  return lane;
}

/** Map generation reference ids to project assets. Audio can't be looked at,
 * so only image and video assets resolve. */
function resolveRefAssets(ids: unknown): AssetRef[] {
  if (ids === undefined || ids === null) return [];
  const s = useEditor.getState();
  return (Array.isArray(ids) ? ids : [ids]).map((raw) => {
    const asset = s.assets.find((a) => a.id === String(raw));
    if (!asset)
      throw new ToolError(`No project asset with id ${String(raw)} — see media in the editor state.`);
    if (asset.type === "audio")
      throw new ToolError(`"${asset.name}" is audio — visual references must be images or videos.`);
    return refFromAsset(asset);
  });
}

/** An overlay clip's frame patch for a layout preset name. */
const OVERLAY_LAYOUT_KEYS = {
  full: "full",
  top: "top",
  bottom: "bottom",
  left: "left",
  right: "right",
  pip: "corner",
} as const;

function layoutPatch(layout: string): Partial<OverlayClip> {
  const key = OVERLAY_LAYOUT_KEYS[layout as keyof typeof OVERLAY_LAYOUT_KEYS];
  if (!key)
    throw new ToolError(`Unknown layout "${layout}". Use full, top, bottom, left, right, or pip.`);
  const L = LAYOUTS[key];
  return { frame: key === "full" ? undefined : { ...L.rect }, fit: L.fit };
}

/** The model asked for timeline placement — explicitly, or implicitly by
 * giving a position. Otherwise generated media stays on its chat card. */
function wantsTimeline(input: Record<string, unknown>, positionKey: "index" | "start"): boolean {
  return input.add_to_timeline === true || isNum(input[positionKey]);
}

const NOT_PLACED = { added: false, clipId: null, index: null };

const promptedIndex = (input: Record<string, unknown>): number | undefined =>
  isNum(input.index) ? Math.round(input.index) : undefined;

/** Append a generated asset to the video track, at `index` when given. Shared
 * by generate_image (inline) and the video renders' completion. */
function addGeneratedClip(
  assetId: string,
  index?: number
): { added: boolean; clipId: string | null; index: number | null } {
  const s = useEditor.getState();
  if (!s.assets.some((a) => a.id === assetId)) return NOT_PLACED;
  s.addClipFromAsset(assetId); // lands at the end, selected
  const sel = useEditor.getState().selection;
  const clipId = sel?.kind === "clip" ? sel.id : null;
  const count = useEditor.getState().clips.length;
  const at = index === undefined ? count - 1 : clamp(Math.round(index), 0, count - 1);
  if (clipId && at !== count - 1) s.moveClip(clipId, at);
  return { added: true, clipId, index: at };
}

/** Start a Veo render — the shared shape of generate_video and
 * generate_character_video: the job previews as a live chat card, the landed
 * asset files under the asking chat, and it goes onto the timeline only when
 * the model asked. Returns the tool output. */
function launchVeoJob(
  projectId: string,
  prompt: string,
  input: Record<string, unknown>,
  opts: Omit<VideoGenOptions, "onDone">
) {
  const addToTimeline = wantsTimeline(input, "index");
  const index = promptedIndex(input);
  // Captured now: the render must file under the chat that asked, even if
  // the user switches threads before it lands.
  const chatId = chatOwner();
  const { jobId } = useGenerate.getState().generateVideo(projectId, prompt, {
    ...opts,
    onDone: (asset) => {
      tagChatAsset(asset.id, chatId);
      if (addToTimeline) addGeneratedClip(asset.id, index);
    },
  });
  return {
    kind: "video",
    started: true,
    jobId,
    addToTimeline,
    note:
      "Rendering with Veo — it previews in this chat when it lands, in a minute or two" +
      (addToTimeline
        ? ", and goes onto the timeline."
        : ". It stays in the chat (and the Video panel's renders) until the user places it."),
  };
}

function titlePatch(input: Record<string, unknown>) {
  const patch: Record<string, unknown> = {};
  if (typeof input.text === "string" && input.text.trim()) patch.text = input.text;
  if (isNum(input.start)) patch.start = Math.max(0, input.start);
  if (isNum(input.end)) patch.end = input.end;
  if (isNum(input.x)) patch.x = clamp(input.x, 0.02, 0.98);
  if (isNum(input.y)) patch.y = clamp(input.y, 0.02, 0.98);
  if (isNum(input.size)) patch.size = clamp(Math.round(input.size), 16, 320);
  if (typeof input.color === "string") patch.color = input.color;
  if (["sf", "serif", "rounded", "mono", "impact"].includes(String(input.font)))
    patch.font = input.font as FontId;
  if (input.weight === 400 || input.weight === 700) patch.weight = input.weight;
  if (typeof input.shadow === "boolean") patch.shadow = input.shadow;
  if (typeof input.plate === "boolean") patch.plate = input.plate;
  if (isNum(input.plateRadius)) patch.plateRadius = clamp(input.plateRadius, 0, 1);
  return patch;
}
