"use client";

import { getClipSpans, totalDuration, useEditor } from "./store";
import { laneCues, subtitleLaneCount } from "./subtitles";
import { isCrossStyle, rectOf, regionLabel, type ClipSpan, type OverlayClip } from "./types";

const r = (n: number) => Math.round(n * 100) / 100;

/** The transition this clip applies into the next one, clamped the same way the
 * preview and export are: a cross dissolve to its overlap, an edge fade/zoom to
 * the clip it ramps. Null when there's no transition or no next clip. */
function transitionToNext(sp: ClipSpan, index: number, spans: ClipSpan[]) {
  const seconds = sp.clip.transition ?? 0;
  if (seconds <= 0 || index >= spans.length - 1) return null;
  const style = sp.clip.transitionStyle ?? "crossfade";
  const next = spans[index + 1];
  const applied = isCrossStyle(style)
    ? sp.transitionOut
    : style === "fadein" || style === "zoomout"
      ? Math.min(seconds, next.len) // edge style ramps the next clip's head
      : Math.min(seconds, sp.len); // edge style ramps this clip's tail
  return { style, seconds: r(applied) };
}

/**
 * Compact JSON snapshot of everything the assistant should know: the cut,
 * the selection, what's on screen, and every user-facing setting. Sent with
 * each message and served by the get_state tool.
 *
 * `fullCues` includes the entire transcript. The per-message snapshot leaves
 * it off (a long transcript would inflate every turn's token cost, even ones
 * that never touch captions); the get_state tool passes it so the model can
 * pull every cue on demand.
 */
export function buildAiContext(opts?: { fullCues?: boolean }) {
  const s = useEditor.getState();
  const cueCap = opts?.fullCues ? Infinity : 60;
  const spans = getClipSpans(s.clips, s.assets);
  const duration = totalDuration(s.clips);
  const assetById = new Map(s.assets.map((a) => [a.id, a]));
  const subtitleTracks = subtitleLaneCount(s.subtitles);

  const selection = (() => {
    if (!s.selection) return null;
    const { kind, id } = s.selection;
    if (kind === "clip") {
      const sp = spans.find((x) => x.clip.id === id);
      return sp
        ? {
            kind,
            id,
            asset: sp.asset.name,
            start: r(sp.start),
            len: r(sp.len),
            muted: sp.clip.muted,
            speed: r(sp.clip.speed ?? 1),
          }
        : { kind, id };
    }
    if (kind === "audio") {
      const a = s.audioClips.find((x) => x.id === id);
      return a ? { kind, id, ...describeAudio(a, assetById) } : { kind, id };
    }
    if (kind === "overlayClip") {
      const c = s.overlayClips.find((x) => x.id === id);
      return c ? { kind, id, ...describeOverlayClip(c, assetById) } : { kind, id };
    }
    if (kind === "cue") {
      const c = s.subtitles.cues.find((x) => x.id === id);
      return c
        ? { kind, id, text: c.text, start: r(c.start), end: r(c.end), track: c.lane ?? 0 }
        : { kind, id };
    }
    const o = s.overlays.find((x) => x.id === id);
    return o ? { kind, id, ...describeOverlay(o) } : { kind, id };
  })();

  return {
    project: {
      id: s.projectId,
      name: s.projectName,
      duration: r(duration),
      aspect: s.aspect,
      frame: s.aspect === "9:16" ? "1080x1920" : "1920x1080",
      ...(s.fadeIn > 0 ? { fadeIn: r(s.fadeIn) } : {}),
      ...(s.fadeOut > 0 ? { fadeOut: r(s.fadeOut) } : {}),
    },
    playhead: r(s.currentTime),
    skimmer: s.skimTime === null ? null : r(s.skimTime),
    playing: s.playing,
    selection,
    // Every project asset, timeline-placed or not. `origin` marks Cut-made
    // media (generated/voiceover/recording/stock/freeze); no origin = a user
    // import shown in the Media panel.
    media: s.assets.slice(0, cueCap).map((a) => ({
      id: a.id,
      name: a.name,
      type: a.type,
      duration: r(a.duration),
      ...(a.origin ? { origin: a.origin } : {}),
    })),
    mediaTruncated: s.assets.length > cueCap,
    videoTrack: spans.map((sp, index) => ({
      index,
      id: sp.clip.id,
      asset: sp.asset.name,
      start: r(sp.start),
      len: r(sp.len),
      in: r(sp.clip.in),
      out: r(sp.clip.out),
      // A still has no source length; report its placed length instead of 0.
      sourceDuration: r(sp.asset.type === "image" ? sp.len : sp.asset.duration),
      muted: sp.clip.muted,
      framing: sp.clip.fit ?? "fit",
      speed: r(sp.clip.speed ?? 1),
      // The base track is free-positioned: empty stretches play black.
      ...(() => {
        const prevEnd = index === 0 ? 0 : spans[index - 1].start + spans[index - 1].len;
        return sp.start - prevEnd > 0.005 ? { gapBefore: r(sp.start - prevEnd) } : {};
      })(),
      ...(() => {
        const t = transitionToNext(sp, index, spans);
        return t ? { transitionToNext: t } : {};
      })(),
      ...(sp.clip.fit === "fill"
        ? { panX: r(sp.clip.panX ?? 0), panY: r(sp.clip.panY ?? 0) }
        : {}),
    })),
    // Video layers composited with the base: track > 0 above it (topmost
    // full-frame clip covers the rest), track < 0 behind it.
    overlayVideo: s.overlayClips.map((c) => ({ id: c.id, ...describeOverlayClip(c, assetById) })),
    soundtrack: s.audioClips.map((a) => ({ id: a.id, ...describeAudio(a, assetById) })),
    titles: s.overlays.map((o) => ({ id: o.id, ...describeOverlay(o) })),
    subtitles: {
      count: s.subtitles.cues.length,
      showOnVideo: s.subtitles.showOnVideo,
      showOnTimeline: s.subtitles.showOnTimeline,
      // One language per track; the active track is what the panel edits and
      // what generation/translation writes to.
      activeTrack: s.subtitleLane,
      tracks: Array.from({ length: subtitleTracks }, (_, i) => ({
        track: i,
        locale:
          s.subtitles.tracks?.[i]?.locale ??
          (i === 0 ? s.subtitles.locale ?? "en-US" : undefined),
        cues: laneCues(s.subtitles, i).length,
      })),
      status: s.subtitleStatus,
      // A window of cues by default; when truncated the model calls get_state
      // for the whole transcript (e.g. "clean up all the captions").
      cues: s.subtitles.cues.slice(0, cueCap).map((c) => ({
        id: c.id,
        start: r(c.start),
        end: r(c.end),
        text: c.text,
        ...(subtitleTracks > 1 ? { track: c.lane ?? 0 } : {}),
      })),
      cuesTruncated: s.subtitles.cues.length > cueCap,
    },
    publish: s.publish,
    view: {
      pxPerSec: r(s.pxPerSec),
      timelineH: s.timelineH,
      exportDialogOpen: s.exportOpen,
    },
  };
}

function describeAudio(
  a: { assetId: string; start: number; in: number; out: number; volume: number; fadeIn?: number; fadeOut?: number; speed?: number; duck?: number; lane?: number },
  assets: Map<string, { name: string }>
) {
  const speed = a.speed && a.speed > 0 ? a.speed : 1;
  return {
    asset: assets.get(a.assetId)?.name ?? a.assetId,
    start: r(a.start),
    len: r((a.out - a.in) / speed),
    in: r(a.in),
    out: r(a.out),
    volume: r(a.volume),
    fadeIn: r(a.fadeIn ?? 0),
    fadeOut: r(a.fadeOut ?? 0),
    ...(speed !== 1 ? { speed: r(speed) } : {}),
    ...(a.lane ? { lane: a.lane } : {}),
    // A voiceover: while it plays, other audio ducks to this gain.
    ...(a.duck !== undefined ? { duck: r(a.duck) } : {}),
  };
}

function describeOverlayClip(c: OverlayClip, assets: Map<string, { name: string }>) {
  const speed = c.speed && c.speed > 0 ? c.speed : 1;
  const rect = rectOf(c);
  return {
    asset: assets.get(c.assetId)?.name ?? c.assetId,
    track: c.track,
    start: r(c.start),
    len: r((c.out - c.in) / speed),
    in: r(c.in),
    out: r(c.out),
    muted: c.muted,
    ...(c.hidden ? { hidden: true } : {}),
    // The frame region this layer occupies: Full covers the base; Top/Bottom/
    // Left/Right split it; PiP floats inside it.
    layout: regionLabel(rect),
    region: { x: r(rect.x), y: r(rect.y), w: r(rect.w), h: r(rect.h) },
    fit: c.fit ?? "fit",
    ...(speed !== 1 ? { speed: r(speed) } : {}),
  };
}

function describeOverlay(o: {
  text: string; start: number; end: number; x: number; y: number;
  size: number; font: string; weight: number; color: string; shadow: boolean; plate: boolean;
  plateRadius?: number; lane?: number;
}) {
  return {
    text: o.text,
    start: r(o.start),
    end: r(o.end),
    x: r(o.x),
    y: r(o.y),
    size: o.size,
    font: o.font,
    weight: o.weight,
    color: o.color,
    shadow: o.shadow,
    plate: o.plate,
    ...(o.plateRadius !== undefined && { plateRadius: r(o.plateRadius) }),
    ...(o.lane ? { lane: o.lane } : {}),
  };
}
