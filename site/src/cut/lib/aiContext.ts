"use client";

import { getClipSpans, totalDuration, useEditor } from "./store";

const r = (n: number) => Math.round(n * 100) / 100;

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
    videoTrack: spans.map((sp, index) => ({
      index,
      id: sp.clip.id,
      asset: sp.asset.name,
      start: r(sp.start),
      len: r(sp.len),
      in: r(sp.clip.in),
      out: r(sp.clip.out),
      sourceDuration: r(sp.asset.duration),
      muted: sp.clip.muted,
      framing: sp.clip.fit ?? "fit",
      speed: r(sp.clip.speed ?? 1),
      ...((sp.clip.transition ?? 0) > 0 && index < spans.length - 1
        ? {
            transitionToNext: {
              style: sp.clip.transitionStyle ?? "crossfade",
              seconds: r(sp.clip.transition ?? 0),
            },
          }
        : {}),
      ...(sp.clip.fit === "fill"
        ? { panX: r(sp.clip.panX ?? 0), panY: r(sp.clip.panY ?? 0) }
        : {}),
    })),
    soundtrack: s.audioClips.map((a) => ({ id: a.id, ...describeAudio(a, assetById) })),
    titles: s.overlays.map((o) => ({ id: o.id, ...describeOverlay(o) })),
    subtitles: {
      count: s.subtitles.cues.length,
      showOnVideo: s.subtitles.showOnVideo,
      showOnTimeline: s.subtitles.showOnTimeline,
      locale: s.subtitles.locale ?? "en-US",
      status: s.subtitleStatus,
      // A window of cues by default; when truncated the model calls get_state
      // for the whole transcript (e.g. "clean up all the captions").
      cues: s.subtitles.cues.slice(0, cueCap).map((c) => ({
        id: c.id,
        start: r(c.start),
        end: r(c.end),
        text: c.text,
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
  a: { assetId: string; start: number; in: number; out: number; volume: number; fadeIn?: number; fadeOut?: number; speed?: number },
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
  };
}

function describeOverlay(o: {
  text: string; start: number; end: number; x: number; y: number;
  size: number; font: string; weight: number; color: string; shadow: boolean; plate: boolean;
  plateRadius?: number;
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
  };
}
