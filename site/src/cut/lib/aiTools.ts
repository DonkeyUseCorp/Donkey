"use client";

import { apiFetch, apiJson } from "./api";
import { useGenerate } from "./generate";
import { enrichAsset, ensurePeaks } from "./media";
import { getClipSpans, TIMELINE_H_MAX, TIMELINE_H_MIN, totalDuration, useEditor } from "./store";
import { buildAiContext } from "./aiContext";
import { resolveVoice, synthesizeSpeech, SPEECH_VOICES } from "./tts";
import { DUCK_DEFAULT, generateSubtitlesReadout } from "./voiceover";
import { FRAME, mediaUrl, TRANSITION_STYLE_IDS, type AudioClip, type FontId, type MediaAsset, type TransitionStyle } from "./types";

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
        kind === "clip" ? s.clips : kind === "audio" ? s.audioClips : kind === "text" ? s.overlays : null;
      if (!pool) throw new ToolError(`Unknown kind: ${kind}`);
      if (!pool.some((x) => x.id === id)) throw new ToolError(`No ${kind} with id ${id}.`);
      s.select({ kind: kind as "clip" | "audio" | "text", id });
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

    case "trim_clip": {
      const clip = requireItem(s.clips, input.clipId, "video clip");
      const asset = s.assets.find((a) => a.id === clip.assetId);
      const dur = asset?.duration ?? clip.out;
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
      const kind = String(input.kind) as "clip" | "audio" | "text";
      const id = String(input.id ?? "");
      const pool = kind === "clip" ? s.clips : kind === "audio" ? s.audioClips : s.overlays;
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
      const asset: MediaAsset = { ...body, url: mediaUrl(projectId, body.fileName) };
      const cur = useEditor.getState();
      cur.addAsset(asset);
      cur.addClipFromAsset(asset.id); // lands at the end, selected
      const sel = useEditor.getState().selection;
      const index = clamp(isNum(input.index) ? Math.round(input.index) : 0, 0, useEditor.getState().clips.length - 1);
      if (sel?.kind === "clip") cur.moveClip(sel.id, index);
      void enrichAsset(asset);
      return {
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

      // Hosted image generation is synchronous and quick, so wait it out and
      // place the still — it lands in Media (and the panel job list) either way.
      const job = await useGenerate.getState().generateImage(projectId, prompt);
      if (job.status !== "done" || !job.assetId) {
        throw new ToolError(job.error ?? "Image generation failed.");
      }
      const cur = useEditor.getState();
      const asset = cur.assets.find((a) => a.id === job.assetId);
      if (!asset) throw new ToolError("The generated image did not land in the project.");
      const placed = maybeAddGeneratedClip(asset.id, input);
      return {
        assetId: asset.id,
        name: asset.name,
        kind: "image",
        duration: Math.round(asset.duration * 100) / 100,
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
      // don't block: start the job and place the clip when it lands.
      const addToTimeline = input.add_to_timeline !== false;
      const promptedIndex = isNum(input.index) ? Math.round(input.index) : undefined;
      void gen.generateVideo(projectId, prompt, {
        tier: input.tier === "high" ? "high" : "fast",
        durationSeconds: isNum(input.duration_seconds)
          ? clamp(Math.round(input.duration_seconds), 4, 8)
          : undefined,
        onDone: addToTimeline
          ? (asset) => maybeAddGeneratedClip(asset.id, { index: promptedIndex })
          : undefined,
      });
      return {
        kind: "video",
        started: true,
        addToTimeline,
        note:
          "Rendering with Veo — it lands in Media" +
          (addToTimeline ? " and on the timeline" : "") +
          " in a minute or two. Track it in the Video panel.",
      };
    }

    case "subtitles_generate": {
      if (typeof input.locale === "string" && input.locale) {
        s.setSubtitlesView({ locale: input.locale });
      }
      await s.generateSubtitles();
      const cur = useEditor.getState();
      if (cur.subtitleStatus === "error")
        throw new ToolError(cur.subtitleError ?? "Transcription failed.");
      if (cur.subtitles.cues.length > 0 && cur.timelineH < 276) cur.setTimelineH(276);
      return {
        status: cur.subtitleStatus,
        cues: cur.subtitles.cues.length,
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
      await s.generateCaptions(style);
      const cur = useEditor.getState();
      if (cur.subtitleStatus === "error")
        throw new ToolError(cur.subtitleError ?? "Captions failed.");
      if (cur.subtitles.cues.length > 0 && cur.timelineH < 276) cur.setTimelineH(276);
      return {
        status: cur.subtitleStatus,
        cues: cur.subtitles.cues.length,
        style: cur.subtitles.style,
        note:
          cur.subtitleStatus === "empty"
            ? "No speech found — no captions were added to the video."
            : undefined,
      };
    }

    case "subtitles_from_visuals": {
      if (typeof input.locale === "string" && input.locale)
        s.setSubtitlesView({ locale: input.locale });
      await s.generateVisualSubtitles();
      const cur = useEditor.getState();
      if (cur.subtitleStatus === "error")
        throw new ToolError(cur.subtitleError ?? "Visual captioning failed.");
      if (cur.subtitles.cues.length > 0 && cur.timelineH < 276) cur.setTimelineH(276);
      return { status: cur.subtitleStatus, cues: cur.subtitles.cues.length };
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
      return synthesizeAndPlace(
        [{ text: input.script, at: 0 }],
        `AI voice — ${lead}`,
        start,
        input
      );
    }

    case "read_subtitles_aloud": {
      if (!s.subtitles.cues.some((c) => c.text.trim()))
        throw new ToolError("No subtitles to read — generate subtitles first.");
      const voice = resolveVoice(typeof input.voice === "string" ? input.voice : undefined);
      // The shared readout also re-times the cues to the generated voice's
      // pace, keeping the word highlighter in step.
      const out = await generateSubtitlesReadout(voice, {
        direction:
          typeof input.direction === "string" && input.direction.trim()
            ? input.direction.trim()
            : undefined,
        duck: isNum(input.duck) ? clamp(input.duck, 0, 1) : undefined,
      });
      const sel = useEditor.getState().selection;
      return {
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
      if (s.subtitles.cues.findIndex((c) => c.id === cue.id) <= 0)
        throw new ToolError("That is the first cue — nothing before it to merge into.");
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
async function synthesizeAndPlace(
  segments: { text: string; at: number }[],
  name: string,
  start: number,
  input: Record<string, unknown>
) {
  const projectId = useEditor.getState().projectId;
  if (!projectId) throw new ToolError("No project open.");
  const voice = resolveVoice(typeof input.voice === "string" ? input.voice : undefined);
  const direction =
    typeof input.direction === "string" && input.direction.trim()
      ? input.direction.trim()
      : undefined;
  const duck = isNum(input.duck) ? clamp(input.duck, 0, 1) : DUCK_DEFAULT;
  const { asset, offset } = await synthesizeSpeech(projectId, segments, {
    voice,
    direction,
    name,
  });
  const cur = useEditor.getState();
  cur.addAsset(asset);
  // A single script lands at `start`; a multi-line readout is pre-offset to its
  // first cue, so it lands at that offset.
  const at = segments.length === 1 ? start : offset;
  cur.addAudioFromAsset(asset.id, at, { duck: duck < 1 ? duck : undefined });
  void enrichAsset(asset);
  const sel = useEditor.getState().selection;
  return {
    audioClipId: sel?.kind === "audio" ? sel.id : null,
    voice,
    start: round2(at),
    duration: round2(asset.duration),
    duck: duck < 1 ? duck : null,
  };
}

function requireItem<T extends { id: string }>(pool: T[], id: unknown, label: string): T {
  const item = pool.find((x) => x.id === String(id ?? ""));
  if (!item) throw new ToolError(`No ${label} with id ${String(id)}. Call get_state for current ids.`);
  return item;
}

/** Append a generated asset to the video track (default) at an optional index.
 * Shared by generate_image (inline) and generate_video (on the render's
 * completion). Respects add_to_timeline:false. */
function maybeAddGeneratedClip(
  assetId: string,
  input: { add_to_timeline?: unknown; index?: unknown }
): { added: boolean; clipId: string | null; index: number | null } {
  if (input.add_to_timeline === false) return { added: false, clipId: null, index: null };
  const s = useEditor.getState();
  if (!s.assets.some((a) => a.id === assetId)) return { added: false, clipId: null, index: null };
  s.addClipFromAsset(assetId); // lands at the end, selected
  const sel = useEditor.getState().selection;
  const clipId = sel?.kind === "clip" ? sel.id : null;
  const count = useEditor.getState().clips.length;
  const index = isNum(input.index) ? clamp(Math.round(input.index), 0, count - 1) : count - 1;
  if (clipId && index !== count - 1) s.moveClip(clipId, index);
  return { added: true, clipId, index };
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
