"use client";

import { useEffect, type RefObject } from "react";
import { clipSpeed, getClipSpans, projectDuration, useEditor } from "@/cut/lib/store";
import { isFullRect, projectFadeSeconds, rectOf, TRANSITION_ZOOM } from "@/cut/lib/types";
import type { AudioClip, ClipSpan, FrameRect, MediaAsset, OverlayClip, VideoClip } from "@/cut/lib/types";

/** The gain everything else drops to at time `t` while a ducking voiceover
 * clip is audible: the lowest `duck` among the clips live then, 1 when none
 * (mirrors the export's timeline-windowed volume filters). */
function duckGainAt(audioClips: AudioClip[], t: number): number {
  let g = 1;
  for (const a of audioClips) {
    if (a.hidden || a.duck === undefined || a.duck >= 1) continue;
    const speed = a.speed && a.speed > 0 ? a.speed : 1;
    const len = Math.max(0.1, (a.out - a.in) / speed);
    if (t >= a.start && t < a.start + len) g = Math.min(g, Math.max(0, a.duck));
  }
  return g;
}

// A base/overlay clip is backed by a <video> for footage or an <img> for a
// still image. These helpers read either kind uniformly so the compositor
// stays one code path — an image never seeks, plays, or carries audio.
type MediaEl = HTMLVideoElement | HTMLImageElement;
const isImageEl = (el: MediaEl): el is HTMLImageElement =>
  typeof HTMLImageElement !== "undefined" && el instanceof HTMLImageElement;
const elReady = (el: MediaEl) =>
  isImageEl(el) ? el.complete && el.naturalWidth > 0 : el.readyState >= 2 && el.videoWidth > 0;
const elW = (el: MediaEl) => (isImageEl(el) ? el.naturalWidth : el.videoWidth);
const elH = (el: MediaEl) => (isImageEl(el) ? el.naturalHeight : el.videoHeight);
// A source that will never become ready: a video decode error, or an image
// that finished loading (`complete`) with no pixels (a broken/unreachable URL).
// The compositor paints through these instead of wedging on them.
const elErrored = (el: MediaEl) =>
  isImageEl(el) ? el.complete && el.naturalWidth === 0 : !!el.error;
const pauseEl = (el: MediaEl) => {
  if (!isImageEl(el) && !el.paused) el.pause();
};
/** Build the decoder element for a clip's asset: an <img> for a still, a
 * hidden <video> for footage. */
function makeMediaEl(asset: MediaAsset): MediaEl {
  if (asset.type === "image") {
    const img = document.createElement("img");
    img.crossOrigin = "anonymous";
    img.src = asset.url;
    return img;
  }
  const v = document.createElement("video");
  v.playsInline = true;
  v.preload = "auto";
  v.crossOrigin = "anonymous";
  v.src = asset.url;
  return v;
}
/** Release an element's source. Images just drop the src; videos stop and
 * unload the decoder. */
function teardown(el: MediaEl) {
  if (isImageEl(el)) {
    el.removeAttribute("src");
    return;
  }
  el.pause();
  el.removeAttribute("src");
  el.load();
}

// The canvas backing store is the full frame resolution (1080×1920 or
// 1920×1080, set by Preview from the project aspect) so the preview stays
// sharp on Retina displays. The engine reads the size off the canvas each
// frame, so an aspect switch takes effect seamlessly.

/**
 * Preview engine. One hidden <video> per base clip and one <audio> per
 * soundtrack clip; the active clip's video element is the master clock while
 * playing and every frame is composited onto the preview canvas (contain-fit,
 * matching the export's letterboxing).
 */
class Engine {
  // Keyed by clip id, not asset id: two trims of the same source get their own
  // decoders, so a cross-dissolve can show both at once and the incoming clip
  // warms during the overlap instead of fighting the outgoing one over a single
  // element's seek head (the black flash between same-source segments).
  private videoEls = new Map<string, MediaEl>();
  // One element per overlay clip (keyed by clip id, not asset) so the same
  // source can appear on two tracks at once.
  private overlayEls = new Map<string, MediaEl>();
  private audioEls = new Map<string, HTMLAudioElement>();
  private raf = 0;
  private activeClipId: string | null = null;
  private disposed = false;
  // Wall-clock stamp for advancing time past the base track, where there is no
  // base video element to act as the master clock.
  private lastPlayNow = 0;

  constructor(private canvas: HTMLCanvasElement) {
    this.tick = this.tick.bind(this);
    this.raf = requestAnimationFrame(this.tick);
  }

  dispose() {
    this.disposed = true;
    cancelAnimationFrame(this.raf);
    for (const el of this.videoEls.values()) teardown(el);
    for (const el of this.overlayEls.values()) teardown(el);
    for (const el of this.audioEls.values()) el.pause();
    this.videoEls.clear();
    this.overlayEls.clear();
    this.audioEls.clear();
  }

  private videoFor(clip: VideoClip, asset: MediaAsset): MediaEl {
    let el = this.videoEls.get(clip.id);
    if (!el) {
      el = makeMediaEl(asset);
      this.videoEls.set(clip.id, el);
    }
    return el;
  }

  /** Seek/rate/play one clip's element toward its frame at timeline time `t`,
   * without touching any other element (the caller pauses stale ones). */
  private prepare(span: ClipSpan, t: number, play: boolean, muted: boolean): MediaEl {
    const el = this.videoFor(span.clip, span.asset);
    // A still never seeks, plays, or carries audio — it's ready as soon as the
    // <img> decodes. Skip every video-clock operation.
    if (isImageEl(el)) return el;
    const speed = clipSpeed(span.clip);
    if (el.playbackRate !== speed) el.playbackRate = speed;
    const target = span.clip.in + Math.max(0, t - span.start) * speed;
    // While playing, the element is its own clock and advances on its own, so
    // only re-seek on a real jump (a clip switch or a scrub) — never for the
    // sub-second lag between this frame's `target` (built from last frame's
    // clock read) and the freely-running element. At high speed that lag is
    // `speed × frameInterval` every frame, which a tight threshold would seek
    // backward each tick, stalling playback. When paused (scrubbing) keep it
    // tight so the frame under the mouse tracks precisely.
    // Let an in-flight seek finish before issuing the next one — restarting
    // the decoder every mousemove makes scrubbing stutter.
    const tol = play ? 0.34 : 0.05;
    if (Math.abs(el.currentTime - target) > tol && !el.seeking) el.currentTime = target;
    el.muted = muted;
    if (play) {
      if (el.paused && el.readyState >= 2) void el.play().catch(() => {});
    } else if (!el.paused) {
      el.pause();
    }
    return el;
  }

  private pauseExcept(keep: Set<string>) {
    for (const [clipId, el] of this.videoEls) {
      if (!keep.has(clipId)) pauseEl(el);
    }
  }

  /** Draw a video element into a sub-region of the frame. "fill" covers the
   * region and crops the overflow (clipped to the rect); "fit" contains the
   * whole picture inside it, centered. `zoom` scales the picture around the
   * region's center (zoom transitions), clipping the overflow to the rect. */
  private drawIntoRect(el: MediaEl, rect: FrameRect, fill: boolean, alpha: number, zoom = 1) {
    const ctx = this.canvas.getContext("2d");
    if (!ctx) return;
    const W = this.canvas.width;
    const H = this.canvas.height;
    const rx = rect.x * W;
    const ry = rect.y * H;
    const rw = rect.w * W;
    const rh = rect.h * H;
    const vw = elW(el);
    const vh = elH(el);
    const sc = (fill ? Math.max(rw / vw, rh / vh) : Math.min(rw / vw, rh / vh)) * zoom;
    const dw = vw * sc;
    const dh = vh * sc;
    const dx = rx + (rw - dw) / 2;
    const dy = ry + (rh - dh) / 2;
    const prevAlpha = ctx.globalAlpha;
    ctx.globalAlpha = Math.max(0, Math.min(1, alpha));
    if (fill || zoom > 1) {
      ctx.save();
      ctx.beginPath();
      ctx.rect(rx, ry, rw, rh);
      ctx.clip();
      ctx.drawImage(el, dx, dy, dw, dh);
      ctx.restore();
    } else {
      ctx.drawImage(el, dx, dy, dw, dh);
    }
    ctx.globalAlpha = prevAlpha;
  }

  private drawLayer(el: MediaEl | null, clip: VideoClip | undefined, clear: boolean, alpha: number, zoom = 1) {
    const ctx = this.canvas.getContext("2d");
    if (!ctx) return;
    const W = this.canvas.width;
    const H = this.canvas.height;
    if (!el) {
      if (clear) {
        ctx.fillStyle = "#000";
        ctx.fillRect(0, 0, W, H);
      }
      return;
    }
    // A hidden clip plays nothing: fill black only if we own the clear,
    // otherwise leave whatever is beneath (a below track) showing.
    if (clip?.hidden) {
      if (clear) {
        ctx.fillStyle = "#000";
        ctx.fillRect(0, 0, W, H);
      }
      return;
    }
    // Mid-seek the element has no decodable frame; keep the previous frame
    // on the canvas instead of strobing black (matters while skimming).
    if (!elReady(el)) return;
    if (clear) {
      ctx.fillStyle = "#000";
      ctx.fillRect(0, 0, W, H);
    }
    // A regioned base clip (split-screen half) draws into its rect over the
    // black frame; the full-frame path below keeps the pan-crop behavior.
    const rect = rectOf(clip ?? {});
    if (!isFullRect(rect)) {
      this.drawIntoRect(el, rect, clip?.fit === "fill", alpha, zoom);
      return;
    }
    const fill = clip?.fit === "fill";
    const vw = elW(el);
    const vh = elH(el);
    const scale = (fill ? Math.max(W / vw, H / vh) : Math.min(W / vw, H / vh)) * zoom;
    const dw = vw * scale;
    const dh = vh * scale;
    let dx = (W - dw) / 2;
    let dy = (H - dh) / 2;
    if (fill) {
      // Pan the crop window across the overflow (matches the export crop).
      const kx = 0.5 + (clip?.panX ?? 0) / 2;
      const ky = 0.5 + (clip?.panY ?? 0) / 2;
      dx = -(dw - W) * kx;
      dy = -(dh - H) * ky;
    }
    const prevAlpha = ctx.globalAlpha;
    ctx.globalAlpha = Math.max(0, Math.min(1, alpha));
    ctx.drawImage(el, dx, dy, dw, dh);
    ctx.globalAlpha = prevAlpha;
  }

  /** Draw `masterSpan` full-frame, plus any transition live at time `t`: a
   * cross style blends (and for cross zoom, scales) the next clip over it — a
   * true A·(1−α)+B·α blend — while an edge style fades or zooms the master's
   * own edge around a hard cut. Returns the master element (the playback
   * clock). */
  private composite(masterSpan: ClipSpan, spans: ClipSpan[], t: number, play: boolean) {
    // A hidden clip is silent as well as black.
    const masterEl = this.prepare(masterSpan, t, play, masterSpan.clip.muted || !!masterSpan.clip.hidden);
    this.activeClipId = masterSpan.clip.id;
    const keep = new Set([masterSpan.clip.id]);
    const idx = spans.indexOf(masterSpan);
    const next = spans[idx + 1];
    const prev = spans[idx - 1];
    const style = masterSpan.clip.transitionStyle ?? "crossfade";
    let incEl: MediaEl | null = null;
    let alpha = 0;
    let masterZoom = 1;
    let incZoom = 1;
    let black = 0; // fade-to-black veil over the base, 0..1
    let gain = 1; // master audio follows the picture through a fade edge
    // Warm the next clip's decoder shortly before its entrance (the dissolve
    // start, or the hard cut) so it enters with a frame already decoded — a
    // cold element would sit invisible for the first frames of the fade.
    if (next && t < next.start && t >= next.start - 1) {
      this.prepare(next, next.start, false, true);
      keep.add(next.clip.id);
    }
    // Cross styles: once the incoming footprint starts, blend it in over the
    // master. Each clip owns its element, so the two decode side by side — a
    // true blend even when they are trims of the same source.
    if (masterSpan.transitionOut > 0 && next && t >= next.start) {
      const p = Math.min(1, (t - next.start) / masterSpan.transitionOut);
      alpha = p;
      incEl = this.prepare(next, t, play, true); // the outgoing clip keeps the audio
      keep.add(next.clip.id);
      if (style === "crosszoom") {
        // The outgoing picture pushes in while the incoming one settles back.
        masterZoom = 1 + (TRANSITION_ZOOM - 1) * p;
        incZoom = TRANSITION_ZOOM - (TRANSITION_ZOOM - 1) * p;
      }
    }
    // Edge style on this clip's own tail (fade out / zoom in).
    if (next && (style === "fadeout" || style === "zoomin")) {
      const d = Math.min(masterSpan.clip.transition ?? 0, masterSpan.len);
      const left = masterSpan.start + masterSpan.len - t;
      if (d > 0 && left < d) {
        const p = 1 - left / d;
        if (style === "fadeout") {
          black = Math.max(black, p);
          gain = Math.min(gain, 1 - p);
        } else {
          masterZoom = 1 + (TRANSITION_ZOOM - 1) * p;
        }
      }
    }
    // Edge style the previous clip set on this clip's head (fade in / zoom out).
    const prevStyle = prev?.clip.transitionStyle ?? "crossfade";
    if (prev && prev.transitionOut === 0 && (prevStyle === "fadein" || prevStyle === "zoomout")) {
      const d = Math.min(prev.clip.transition ?? 0, masterSpan.len);
      const rel = t - masterSpan.start;
      if (d > 0 && rel < d) {
        const p = rel / d;
        if (prevStyle === "fadein") {
          black = Math.max(black, 1 - p);
          gain = Math.min(gain, p);
        } else {
          masterZoom = TRANSITION_ZOOM - (TRANSITION_ZOOM - 1) * p;
        }
      }
    }
    // A live voiceover ducks the base clip's sound under it. The clip's own
    // volume rides on top (the element clamps at 1; export honors up to 1.5).
    const duck = duckGainAt(useEditor.getState().audioClips, t);
    if (!isImageEl(masterEl)) {
      masterEl.volume = Math.max(0, Math.min(1, gain * duck * (masterSpan.clip.volume ?? 1)));
    }
    this.pauseExcept(keep);
    // No clear here — the tick clears once, then draws the below tracks, so the
    // base composites over them (a regioned base leaves them showing).
    this.drawLayer(masterEl, masterSpan.clip, false, 1, masterZoom);
    if (incEl) this.drawLayer(incEl, next!.clip, false, alpha, incZoom);
    // Veil only the base's own footprint, like the export's per-clip fade
    // filter: a regioned base darkens inside its rect while a below track shows
    // through the margins; tracks drawn after (above the base) stay lit.
    if (black > 0) this.fillBlackVeil(black, rectOf(masterSpan.clip));
    return masterEl;
  }

  private overlayVideoFor(clip: OverlayClip, asset: MediaAsset): MediaEl {
    let el = this.overlayEls.get(clip.id);
    if (!el) {
      el = makeMediaEl(asset);
      // Overlay audio is mixed on export, not previewed here.
      if (!isImageEl(el)) el.muted = true;
      this.overlayEls.set(clip.id, el);
    }
    return el;
  }

  private clearCanvas() {
    const ctx = this.canvas.getContext("2d");
    if (!ctx) return;
    ctx.fillStyle = "#000";
    ctx.fillRect(0, 0, this.canvas.width, this.canvas.height);
  }

  /** Whole-video fade gain at time `t`: ramps 0→1 over the project fade-in and
   * 1→0 over the fade-out at the end of the cut. 1 when neither applies. */
  private projectFadeGain(t: number, total: number) {
    const s = useEditor.getState();
    const fadeIn = projectFadeSeconds(s.fadeIn, total);
    const fadeOut = projectFadeSeconds(s.fadeOut, total);
    let g = 1;
    if (fadeIn > 0 && t < fadeIn) g = Math.min(g, Math.max(0, t / fadeIn));
    if (fadeOut > 0 && t > total - fadeOut) g = Math.min(g, Math.max(0, (total - t) / fadeOut));
    return Math.min(1, g);
  }

  /** Paint an `amount` (0..1) black veil — over the whole frame, or clipped to
   * `rect` for a per-clip fade. Shared by the edge-transition fade and the
   * whole-video project fade so the two can never drift apart. */
  private fillBlackVeil(amount: number, rect?: FrameRect) {
    if (amount <= 0) return;
    const ctx = this.canvas.getContext("2d");
    if (!ctx) return;
    const W = this.canvas.width;
    const H = this.canvas.height;
    ctx.fillStyle = `rgba(0,0,0,${Math.min(1, amount).toFixed(3)})`;
    if (rect) ctx.fillRect(rect.x * W, rect.y * H, rect.w * W, rect.h * H);
    else ctx.fillRect(0, 0, W, H);
  }

  /** The picture side of the project fade: a black veil over the whole frame
   * (everything drawn this tick — base, tracks, at any time), matching the
   * export's fade on the final composite. */
  private drawProjectFade(gain: number) {
    this.fillBlackVeil(1 - gain);
  }

  /** Overlay clips live at time `t` on one side of the base — `below`
   * (track < 0) or `above` (track > 0) — with their assets, in z-order
   * (further-back first). */
  private liveOverlays(t: number, side: "below" | "above") {
    const s = useEditor.getState();
    const live: { clip: OverlayClip; asset: MediaAsset }[] = [];
    const clips = s.overlayClips
      .filter((c) => (side === "below" ? c.track < 0 : c.track > 0))
      .sort((a, b) => a.track - b.track);
    for (const c of clips) {
      if (c.hidden) continue;
      const asset = s.assets.find((a) => a.id === c.assetId);
      if (!asset) continue;
      const speed = c.speed && c.speed > 0 ? c.speed : 1;
      const len = Math.max(0.1, (c.out - c.in) / speed);
      if (t < c.start || t >= c.start + len) continue;
      live.push({ clip: c, asset });
    }
    return live;
  }

  /** Seek/rate/play one overlay clip's element toward its frame at timeline
   * time `t` (the overlay counterpart of `prepare`). */
  private prepareOverlay(clip: OverlayClip, asset: MediaAsset, t: number, play: boolean): MediaEl {
    const el = this.overlayVideoFor(clip, asset);
    if (isImageEl(el)) return el;
    const speed = clip.speed && clip.speed > 0 ? clip.speed : 1;
    if (el.playbackRate !== speed) el.playbackRate = speed;
    const target = clip.in + Math.max(0, t - clip.start) * speed;
    const tol = play ? 0.34 : 0.05;
    if (Math.abs(el.currentTime - target) > tol && !el.seeking) el.currentTime = target;
    if (play) {
      if (el.paused && el.readyState >= 2) void el.play().catch(() => {});
    } else if (!el.paused) {
      el.pause();
    }
    return el;
  }

  /** Live overlays for one side, each already primed toward `t`. Computed once
   * so the skim path's readiness check and the draw step share the same
   * filter/sort/seek instead of repeating it per frame. */
  private prepareSide(t: number, play: boolean, side: "below" | "above") {
    return this.liveOverlays(t, side).map(({ clip, asset }) => ({
      clip,
      el: this.prepareOverlay(clip, asset, t, play),
    }));
  }

  /** Draw the overlay tracks on one side of the base — `below` (track < 0) or
   * `above` (track > 0) — in z-order (further-back first). A full-frame clip
   * covers what's under it; a regioned one shares the frame, letting lower
   * tracks show in its margins. Collects the clips it touched into `active`.
   * Pass `prepared` (from `prepareSide`) to reuse an already-primed side. */
  private drawOverlays(
    t: number,
    play: boolean,
    side: "below" | "above",
    active: Set<string>,
    prepared?: { clip: OverlayClip; el: MediaEl }[]
  ) {
    for (const { clip, el } of prepared ?? this.prepareSide(t, play, side)) {
      active.add(clip.id);
      if (!elReady(el)) continue;
      const rect = rectOf(clip);
      const cover = clip.fit === "fill" || (clip.fit == null && isFullRect(rect));
      this.drawIntoRect(el, rect, cover, 1);
    }
  }

  /** Pause overlay elements not drawn this frame; drop those whose clip is gone. */
  private cleanupOverlays(active: Set<string>) {
    const s = useEditor.getState();
    for (const [id, el] of this.overlayEls) {
      if (active.has(id)) continue;
      pauseEl(el);
      if (!s.overlayClips.some((c) => c.id === id)) {
        teardown(el);
        this.overlayEls.delete(id);
      }
    }
  }

  private syncSoundtrack(t: number, playing: boolean, fadeGain = 1) {
    const s = useEditor.getState();
    const live = new Set<string>();
    for (const a of s.audioClips) {
      live.add(a.id);
      const asset = s.assets.find((x) => x.id === a.assetId);
      if (!asset) continue;
      let el = this.audioEls.get(a.id);
      if (!el) {
        el = new Audio(asset.url);
        el.preload = "auto";
        this.audioEls.set(a.id, el);
      }
      // Detached audio can carry its video clip's rate; footprint is (out-in)/speed.
      const speed = a.speed && a.speed > 0 ? a.speed : 1;
      const len = Math.max(0.1, (a.out - a.in) / speed);
      // A hidden clip is muted from the mix — keep its element but never play it.
      const active = playing && !a.hidden && t >= a.start && t < a.start + len;
      if (active) {
        // Fade envelope: linear ramps at either end of the clip.
        const rel = t - a.start;
        const fi = a.fadeIn ?? 0;
        const fo = a.fadeOut ?? 0;
        let gain = 1;
        if (fi > 0 && rel < fi) gain *= rel / fi;
        if (fo > 0 && rel > len - fo) gain *= Math.max(0, (len - rel) / fo);
        // A live voiceover ducks the other soundtrack clips (music) too;
        // ducking clips never duck each other.
        const dg = a.duck !== undefined && a.duck < 1 ? 1 : duckGainAt(s.audioClips, t);
        el.volume = Math.max(0, Math.min(1, a.volume * gain * dg * fadeGain));
        if (el.playbackRate !== speed) el.playbackRate = speed;
        const expected = a.in + rel * speed;
        if (Math.abs(el.currentTime - expected) > 0.25) el.currentTime = expected;
        if (el.paused) void el.play().catch(() => {});
      } else if (!el.paused) {
        el.pause();
      }
    }
    for (const [id, el] of this.audioEls) {
      if (!live.has(id)) {
        el.pause();
        this.audioEls.delete(id);
      }
    }
  }

  private tick() {
    if (this.disposed) return;
    this.raf = requestAnimationFrame(this.tick);

    const s = useEditor.getState();
    const spans = getClipSpans(s.clips, s.assets);
    // Drop decoders for clips that no longer exist (deleted or replaced).
    if (this.videoEls.size > s.clips.length) {
      const live = new Set(s.clips.map((c) => c.id));
      for (const [id, el] of this.videoEls) {
        if (live.has(id)) continue;
        teardown(el);
        this.videoEls.delete(id);
      }
    }
    // Whole-project length so time past the base (a longer upper/lower track or
    // soundtrack) is still reachable while scrubbing and playing.
    const total = projectDuration(s);

    if (spans.length === 0) {
      this.pauseExcept(new Set());
      this.drawLayer(null, undefined, true, 1);
      this.syncSoundtrack(0, false);
      if (s.playing) useEditor.setState({ playing: false, currentTime: 0 });
      return;
    }

    let t = Math.min(s.currentTime, total);

    if (!s.playing) {
      // Not advancing: drop the wall-clock stamp so the first playing tick
      // starts a fresh delta instead of leaping over the paused stretch.
      this.lastPlayNow = 0;
      // iMovie skimming: while the mouse hovers the timeline, preview the
      // frame under it. The playhead (currentTime) is never touched.
      const pt =
        s.skimTime !== null ? Math.max(0, Math.min(s.skimTime, total - 0.001)) : t;
      const span = spans.find((sp) => pt >= sp.start && pt < sp.start + sp.len);
      // Prime every layer live at `pt` — the base element and each overlay
      // track — before repainting (create them, issue any seeks). A cold
      // element or an unbuffered seek has no decodable frame yet, and painting
      // around it tears the composite: black before the base's seek resolves,
      // or the base flashing through where an overlay covers it. Hold the last
      // painted frame until every live layer has a frame, so each scrubbed
      // frame is the same composite playback and export show.
      let ready = true;
      if (span) {
        const el = this.prepare(span, Math.min(pt, span.start + span.len), false, true);
        // A broken source never becomes ready; paint without it rather than
        // wedging the preview on it.
        if (!elErrored(el) && !elReady(el)) ready = false;
      }
      // Prime each side once; the readiness scan and the draw step below reuse
      // these instead of re-filtering/seeking the overlays a second time.
      const belowLive = this.prepareSide(pt, false, "below");
      const aboveLive = this.prepareSide(pt, false, "above");
      for (const { el } of [...belowLive, ...aboveLive]) {
        if (!elErrored(el) && !elReady(el)) ready = false;
      }
      if (!ready) {
        this.pauseExcept(new Set(span ? [span.clip.id] : []));
        this.syncSoundtrack(t, false);
        return;
      }
      const active = new Set<string>();
      this.clearCanvas();
      this.drawOverlays(pt, false, "below", active, belowLive);
      // Past the base track there is no base frame — just the backdrop and the
      // upper/lower tracks that are still running at `pt`.
      if (span) this.composite(span, spans, Math.min(pt, span.start + span.len), false);
      else this.pauseExcept(new Set());
      this.drawOverlays(pt, false, "above", active, aboveLive);
      this.drawProjectFade(this.projectFadeGain(pt, total));
      this.cleanupOverlays(active);
      this.syncSoundtrack(t, false);
      return;
    }

    let span = spans.find((sp) => t >= sp.start && t < sp.start + sp.len);

    // A just-started or just-scrubbed clip may still be decoding. Hold the last
    // painted frame rather than clearing to black — same as the skim path. (At a
    // dissolve boundary the incoming clip is already warm from the overlap, so
    // this only bites a genuinely cold first frame.)
    if (span) {
      const el = this.prepare(span, t, true, span.clip.muted || !!span.clip.hidden);
      // A broken source (unreachable still, decode error) never becomes ready;
      // fall through so the wall clock advances past it instead of freezing.
      if (!elReady(el) && !elErrored(el)) {
        this.pauseExcept(new Set([span.clip.id]));
        this.syncSoundtrack(t, true);
        return;
      }
    }

    // Draw the below tracks first (backdrop), then prime the master element
    // (and any dissolve partner) over them and read the clock.
    const active = new Set<string>();
    this.clearCanvas();
    this.drawOverlays(t, true, "below", active);

    if (span) {
      let el = this.composite(span, spans, t, true);
      // The element clock is the truth but it's coarse: currentTime advances in
      // steps bigger than a frame, and copying it straight to the playhead
      // makes the indicator stutter and step backward. Advance by wall clock
      // instead — smooth by construction and never backward — and let the
      // element clock steer it: the playhead may run at most 60ms ahead of the
      // clock (a stalled element halts it with the picture) and snaps forward
      // only when the clock genuinely leads.
      const now = performance.now();
      const dt = this.lastPlayNow ? Math.min(0.25, (now - this.lastPlayNow) / 1000) : 0;
      let atEnd: boolean;
      if (isImageEl(el)) {
        // A still has no element clock — advance purely by wall clock and end
        // at the clip's timeline footprint.
        t = Math.max(span.start, Math.min(t + dt, span.start + span.len));
        atEnd = t >= span.start + span.len - 0.0001;
      } else {
        const speed = clipSpeed(span.clip);
        const derived = span.start + (el.currentTime - span.clip.in) / speed;
        const cand = Math.min(t + dt, derived + 0.06);
        t = derived - cand > 0.25 ? derived : Math.max(t, cand);
        t = Math.max(span.start, Math.min(t, span.start + span.len));
        atEnd = el.currentTime >= span.clip.out - 0.02 || el.ended;
      }
      // Clip boundary: hand off to the next clip when it abuts (or dissolves),
      // fall into the gap when it doesn't — the base plays black there and the
      // wall clock advances — or (if the base is done but an upper/lower track
      // runs on) fall through to the wall-clock tail.
      if (atEnd) {
        const idx = spans.indexOf(span);
        const next = spans[idx + 1];
        if (next && next.start <= span.start + span.len + 0.001) {
          // Jump past the finished clip's whole footprint (including any
          // cross-dissolve overlap), not back to next.start — which still sits
          // inside the outgoing clip's footprint, so find() would re-pick the
          // clip we just finished and playback would ping-pong across the
          // dissolve forever.
          t = Math.max(next.start + 0.0001, span.start + span.len);
          span = next;
          el = this.composite(next, spans, t, true);
        } else if (next) {
          // A gap before the next clip: step just past this clip's footprint
          // so the next tick's find() sees no active span and the wall-clock
          // path carries time (and the soundtrack) across the black stretch.
          t = Math.max(t, span.start + span.len + 0.0001);
          pauseEl(el);
        } else if (t >= total - 0.001) {
          // Base and every other track finished.
          useEditor.setState({ playing: false, currentTime: total });
          pauseEl(el);
          this.drawOverlays(t, true, "above", active);
          this.drawProjectFade(this.projectFadeGain(total, total));
          this.cleanupOverlays(active);
          this.syncSoundtrack(total, false);
          return;
        }
      }
      this.lastPlayNow = now;
    } else {
      // Past the base track but an upper/lower track is still playing: no master
      // element, so advance time by the wall clock and let the overlays follow.
      this.pauseExcept(new Set());
      const now = performance.now();
      const dt = this.lastPlayNow ? Math.min(0.25, (now - this.lastPlayNow) / 1000) : 0;
      this.lastPlayNow = now;
      t = t + dt;
      if (t >= total - 0.001) {
        useEditor.setState({ playing: false, currentTime: total });
        this.drawOverlays(t, true, "above", active);
        this.drawProjectFade(this.projectFadeGain(total, total));
        this.cleanupOverlays(active);
        this.syncSoundtrack(total, false);
        return;
      }
    }

    this.drawOverlays(t, true, "above", active);
    // The whole-video fade veils the finished frame and dims the sound —
    // the master's element volume (set by composite) and the soundtrack.
    const fadeGain = this.projectFadeGain(t, total);
    if (fadeGain < 1 && span) {
      const mel = this.videoEls.get(span.clip.id);
      if (mel && !isImageEl(mel)) mel.volume = Math.min(mel.volume, fadeGain);
    }
    this.drawProjectFade(fadeGain);
    this.cleanupOverlays(active);
    useEditor.setState({ currentTime: t });
    this.syncSoundtrack(t, true, fadeGain);
  }
}

export function usePlayback(canvasRef: RefObject<HTMLCanvasElement | null>) {
  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const engine = new Engine(canvas);
    return () => engine.dispose();
  }, [canvasRef]);
}
