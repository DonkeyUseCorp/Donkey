"use client";

import { useEffect, type RefObject } from "react";
import { getClipSpans, totalDuration, useEditor } from "@/cut/lib/store";
import type { ClipSpan, MediaAsset, VideoClip } from "@/cut/lib/types";

// The canvas backing store is the full frame resolution (1080×1920 or
// 1920×1080, set by Preview from the project aspect) so the preview stays
// sharp on Retina displays. The engine reads the size off the canvas each
// frame, so an aspect switch takes effect seamlessly.

/**
 * Preview engine. One hidden <video> per asset and one <audio> per soundtrack
 * clip; the active clip's video element is the master clock while playing and
 * every frame is composited onto the preview canvas (contain-fit, matching the
 * export's letterboxing).
 */
class Engine {
  private videoEls = new Map<string, HTMLVideoElement>();
  private audioEls = new Map<string, HTMLAudioElement>();
  private raf = 0;
  private activeClipId: string | null = null;
  private lastWritten = -1;
  private disposed = false;

  constructor(private canvas: HTMLCanvasElement) {
    this.tick = this.tick.bind(this);
    this.raf = requestAnimationFrame(this.tick);
  }

  dispose() {
    this.disposed = true;
    cancelAnimationFrame(this.raf);
    for (const el of this.videoEls.values()) {
      el.pause();
      el.removeAttribute("src");
      el.load();
    }
    for (const el of this.audioEls.values()) el.pause();
    this.videoEls.clear();
    this.audioEls.clear();
  }

  private videoFor(asset: MediaAsset) {
    let el = this.videoEls.get(asset.id);
    if (!el) {
      el = document.createElement("video");
      el.playsInline = true;
      el.preload = "auto";
      el.crossOrigin = "anonymous";
      el.src = asset.url;
      this.videoEls.set(asset.id, el);
    }
    return el;
  }

  private switchTo(span: ClipSpan, t: number, play: boolean) {
    const el = this.videoFor(span.asset);
    for (const [assetId, other] of this.videoEls) {
      if (assetId !== span.asset.id && !other.paused) other.pause();
    }
    const target = span.clip.in + Math.max(0, t - span.start);
    // Let an in-flight seek finish before issuing the next one — restarting
    // the decoder every mousemove makes scrubbing stutter. The tick loop
    // re-applies the newest target as soon as the element is free.
    if (Math.abs(el.currentTime - target) > 0.05 && !el.seeking) el.currentTime = target;
    this.activeClipId = span.clip.id;
    if (play) void el.play().catch(() => {});
    return el;
  }

  private draw(el: HTMLVideoElement | null, clip?: VideoClip) {
    const ctx = this.canvas.getContext("2d");
    if (!ctx) return;
    const W = this.canvas.width;
    const H = this.canvas.height;
    if (!el) {
      ctx.fillStyle = "#000";
      ctx.fillRect(0, 0, W, H);
      return;
    }
    // Mid-seek the element has no decodable frame; keep the previous frame
    // on the canvas instead of strobing black (matters while skimming).
    if (el.readyState < 2 || !el.videoWidth) return;
    ctx.fillStyle = "#000";
    ctx.fillRect(0, 0, W, H);
    const fill = clip?.fit === "fill";
    const scale = fill
      ? Math.max(W / el.videoWidth, H / el.videoHeight)
      : Math.min(W / el.videoWidth, H / el.videoHeight);
    const dw = el.videoWidth * scale;
    const dh = el.videoHeight * scale;
    let dx = (W - dw) / 2;
    let dy = (H - dh) / 2;
    if (fill) {
      // Pan the crop window across the overflow (matches the export crop).
      const kx = 0.5 + (clip?.panX ?? 0) / 2;
      const ky = 0.5 + (clip?.panY ?? 0) / 2;
      dx = -(dw - W) * kx;
      dy = -(dh - H) * ky;
    }
    ctx.drawImage(el, dx, dy, dw, dh);
  }

  private syncSoundtrack(t: number, playing: boolean) {
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
      const len = Math.max(0.1, a.out - a.in);
      const active = playing && t >= a.start && t < a.start + len;
      if (active) {
        // Fade envelope: linear ramps at either end of the clip.
        const rel = t - a.start;
        const fi = a.fadeIn ?? 0;
        const fo = a.fadeOut ?? 0;
        let gain = 1;
        if (fi > 0 && rel < fi) gain *= rel / fi;
        if (fo > 0 && rel > len - fo) gain *= Math.max(0, (len - rel) / fo);
        el.volume = Math.max(0, Math.min(1, a.volume * gain));
        const expected = a.in + (t - a.start);
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
    const total = totalDuration(s.clips);

    if (spans.length === 0) {
      this.draw(null);
      this.syncSoundtrack(0, false);
      if (s.playing) useEditor.setState({ playing: false, currentTime: 0 });
      return;
    }

    let t = Math.min(s.currentTime, total);
    const externalSeek = Math.abs(t - this.lastWritten) > 0.15;

    if (!s.playing) {
      for (const el of this.videoEls.values()) if (!el.paused) el.pause();
      // iMovie skimming: while the mouse hovers the timeline, preview the
      // frame under it. The playhead (currentTime) is never touched.
      const pt =
        s.skimTime !== null ? Math.max(0, Math.min(s.skimTime, total - 0.001)) : t;
      const span =
        spans.find((sp) => pt >= sp.start && pt < sp.start + sp.len) ??
        spans[spans.length - 1];
      const el = this.switchTo(span, Math.min(pt, span.start + span.len), false);
      this.lastWritten = t;
      this.draw(el, span.clip);
      this.syncSoundtrack(t, false);
      return;
    }

    let span = spans.find((sp) => t >= sp.start && t < sp.start + sp.len);
    if (!span) {
      // Reached the end of the last clip.
      useEditor.setState({ playing: false, currentTime: total });
      this.lastWritten = total;
      for (const el of this.videoEls.values()) el.pause();
      this.syncSoundtrack(total, false);
      return;
    }

    let el = this.videoFor(span.asset);
    if (span.clip.id !== this.activeClipId || externalSeek) {
      el = this.switchTo(span, t, true);
    }
    el.muted = span.clip.muted;
    if (el.paused && el.readyState >= 2) void el.play().catch(() => {});

    // The active element is the master clock.
    const derived = span.start + (el.currentTime - span.clip.in);
    if (Math.abs(derived - t) < 1.5) {
      t = Math.max(span.start, Math.min(derived, span.start + span.len));
    }

    // Clip boundary: hand off to the next clip (or finish).
    if (el.currentTime >= span.clip.out - 0.02 || el.ended) {
      const idx = spans.indexOf(span);
      const next = spans[idx + 1];
      if (next) {
        t = next.start + 0.0001;
        span = next;
        el = this.switchTo(next, t, true);
        el.muted = next.clip.muted;
      } else {
        useEditor.setState({ playing: false, currentTime: total });
        this.lastWritten = total;
        el.pause();
        this.draw(el, span.clip);
        this.syncSoundtrack(total, false);
        return;
      }
    }

    this.lastWritten = t;
    useEditor.setState({ currentTime: t });
    this.draw(el, span.clip);
    this.syncSoundtrack(t, true);
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
