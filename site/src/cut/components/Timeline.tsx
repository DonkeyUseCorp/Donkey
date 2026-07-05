"use client";

import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { AudioLines, EllipsisVertical, Music, Pause, Play, Plus, Scissors, SkipBack, Trash2, Type, VolumeX } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Slider } from "@/components/ui/slider";
import { draggedAssetId, hasAssetDrag } from "@/cut/lib/assetDrag";
import { startDrag } from "@/cut/lib/drag";
import { ensurePeaks } from "@/cut/lib/media";
import { clipLen, getClipSpans, TIMELINE_H_MAX, totalDuration, useEditor } from "@/cut/lib/store";
import { formatTime, formatTimecode } from "@/cut/lib/time";
import type { AudioClip, ClipSpan, MediaAsset, SubtitleCue, TextOverlay } from "@/cut/lib/types";
import { cn } from "@/lib/utils";

const VIDEO_H = 64;
const AUDIO_H = 44;
const TEXT_H = 28;
const SUB_H = 22;
const PAD_END = 320;
/** Breathing room on both sides so the playhead cap is never clipped. */
const PAD_SIDE = 20;
/** Visual gutter between adjacent clips (iMovie); time math stays exact. */
const CLIP_GAP = 4;

const SELECTED_SHADOW =
  "shadow-[inset_0_0_0_2px_#0a84ff,0_0_12px_rgba(10,132,255,0.25)]";

const trimHandle =
  "tl-trim absolute top-0 bottom-0 z-3 w-[10px] cursor-ew-resize after:absolute after:top-1/2 after:left-[3px] after:h-[calc(100%-10px)] after:w-1 after:-translate-y-1/2 after:rounded-full after:bg-white after:opacity-0 after:shadow-[0_0_0_1px_rgba(0,0,0,0.35)] after:transition-opacity group-hover:after:opacity-90 hover:after:opacity-100";

/** Live reorder-drag on the video track: ghost offset plus the open slot. */
interface ClipDrag {
  id: string;
  dx: number; // ghost offset in px (mouse + auto-scroll)
  dy: number; // vertical lift in px, clamped — iMovie's picked-up feel
  from: number; // original index in spans
  to: number; // insertion index while dragging
  len: number; // dragged clip length, seconds
  gapStart: number; // open slot position, seconds
}

/**
 * Insertion index for a dragged clip (iMovie): the edge leading the drag
 * direction opens a slot once it crosses a neighbor's midpoint.
 */
function dropIndex(spans: ClipSpan[], from: number, dxSec: number): number {
  const d = spans[from];
  let to = from;
  if (dxSec > 0) {
    const edge = d.start + d.len + dxSec; // right edge leads
    for (let k = from + 1; k < spans.length; k++)
      if (edge > spans[k].start + spans[k].len / 2) to = k;
  } else if (dxSec < 0) {
    const edge = d.start + dxSec; // left edge leads
    for (let k = from - 1; k >= 0; k--)
      if (edge < spans[k].start + spans[k].len / 2) to = k;
  }
  return to;
}

export function Timeline() {
  const clips = useEditor((s) => s.clips);
  const audioClips = useEditor((s) => s.audioClips);
  const overlays = useEditor((s) => s.overlays);
  const assets = useEditor((s) => s.assets);
  const pps = useEditor((s) => s.pxPerSec);
  const timelineH = useEditor((s) => s.timelineH);
  const selection = useEditor((s) => s.selection);
  const subtitles = useEditor((s) => s.subtitles);
  const scrollRef = useRef<HTMLDivElement>(null);
  const innerRef = useRef<HTMLDivElement>(null);

  const spans = useMemo(() => getClipSpans(clips, assets), [clips, assets]);
  const total = totalDuration(clips);
  const contentW = Math.max(total * pps + PAD_END, 900);

  // Reorder drag on the video track: neighbors part to open a highlighted
  // slot at the insertion point; releasing drops the clip into it.
  const [clipDrag, setClipDrag] = useState<{ id: string; dx: number; dy: number } | null>(null);
  const dragInfo = useMemo<ClipDrag | null>(() => {
    if (!clipDrag) return null;
    const from = spans.findIndex((sp) => sp.clip.id === clipDrag.id);
    if (from < 0) return null;
    const to = dropIndex(spans, from, clipDrag.dx / pps);
    const len = spans[from].len;
    const gapStart = to <= from ? spans[to].start : spans[to].start + spans[to].len - len;
    return { id: clipDrag.id, dx: clipDrag.dx, dy: clipDrag.dy, from, to, len, gapStart };
  }, [clipDrag, spans, pps]);

  const onClipDrag = useCallback(
    (id: string, dx: number, dy: number) => setClipDrag({ id, dx, dy }),
    []
  );
  const onClipDrop = useCallback((id: string, dx: number | null) => {
    setClipDrag(null);
    if (dx === null) return;
    const s = useEditor.getState();
    const sp = getClipSpans(s.clips, s.assets);
    const from = sp.findIndex((x) => x.clip.id === id);
    if (from >= 0) s.moveClip(id, dropIndex(sp, from, dx / s.pxPerSec));
  }, []);

  const timeAt = (clientX: number) => {
    const rect = innerRef.current!.getBoundingClientRect();
    return (clientX - rect.left) / pps;
  };

  // Scrub with auto-scroll when the pointer nears the viewport edges.
  const scrub = (e: React.PointerEvent) => {
    const s = useEditor.getState();
    s.seek(timeAt(e.clientX));
    const el = scrollRef.current;
    startDrag(e, {
      onMove: (_dx, _dy, ev) => {
        if (el) {
          const r = el.getBoundingClientRect();
          if (ev.clientX > r.right - 36) el.scrollLeft += 14;
          else if (ev.clientX < r.left + 36) el.scrollLeft -= 14;
        }
        useEditor.getState().seek(timeAt(ev.clientX));
      },
    });
  };

  // Clicking empty track space deselects AND moves the playhead (iMovie).
  const deselectIfSelf = (e: React.PointerEvent) => {
    if (e.target === e.currentTarget) {
      useEditor.getState().select(null);
      scrub(e);
    }
  };

  // Zoom that keeps a chosen time pinned under a chosen viewport x.
  const pendingAnchor = useRef<{ t: number; px: number } | null>(null);
  useLayoutEffect(() => {
    const el = scrollRef.current;
    const a = pendingAnchor.current;
    if (el && a) {
      el.scrollLeft = Math.max(0, PAD_SIDE + a.t * pps - a.px);
      pendingAnchor.current = null;
    }
  }, [pps]);

  const zoomTo = useCallback((next: number, anchorT?: number, anchorPx?: number) => {
    const el = scrollRef.current;
    const cur = useEditor.getState();
    const clamped = Math.max(12, Math.min(800, next));
    if (Math.abs(clamped - cur.pxPerSec) < 0.01) return;
    if (el) {
      const t = anchorT ?? cur.currentTime;
      const px = anchorPx ?? PAD_SIDE + t * cur.pxPerSec - el.scrollLeft;
      pendingAnchor.current = { t, px };
    }
    cur.setPxPerSec(clamped);
  }, []);

  const fit = useCallback(() => {
    const el = scrollRef.current;
    const dur = totalDuration(useEditor.getState().clips);
    if (!el || dur <= 0) return;
    zoomTo((el.clientWidth - 60) / dur, 0, PAD_SIDE);
  }, [zoomTo]);

  // Trackpad pinch / cmd+wheel zooms at the cursor; vertical wheel pans.
  useEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    const onWheel = (e: WheelEvent) => {
      if (e.ctrlKey || e.metaKey) {
        e.preventDefault();
        const rect = el.getBoundingClientRect();
        const px = e.clientX - rect.left;
        const cur = useEditor.getState().pxPerSec;
        const t = (el.scrollLeft + px - PAD_SIDE) / cur;
        zoomTo(cur * Math.exp(-e.deltaY * 0.012), t, px);
      } else if (Math.abs(e.deltaY) > Math.abs(e.deltaX)) {
        e.preventDefault();
        el.scrollLeft += e.deltaY;
      }
    };
    el.addEventListener("wheel", onWheel, { passive: false });
    return () => el.removeEventListener("wheel", onWheel);
  }, [zoomTo]);

  // Timeline-scoped keys: = / - zoom around the playhead, Home/End jump.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement;
      if (
        target.tagName === "INPUT" ||
        target.tagName === "TEXTAREA" ||
        target.tagName === "SELECT" ||
        target.isContentEditable ||
        document.querySelector('[data-slot="dialog-content"]')
      )
        return;
      const s = useEditor.getState();
      if (e.key === "=" || e.key === "+") {
        e.preventDefault();
        zoomTo(s.pxPerSec * 1.3);
      } else if (e.key === "-" || e.key === "_") {
        e.preventDefault();
        zoomTo(s.pxPerSec / 1.3);
      } else if (e.key === "Home") {
        e.preventDefault();
        s.seek(0);
      } else if (e.key === "End") {
        e.preventDefault();
        s.seek(totalDuration(s.clips));
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [zoomTo]);

  // Drag the panel's top border to resize; the border itself stays as-is,
  // only an invisible grab strip sits on top of it.
  const resize = (e: React.PointerEvent) => {
    const h0 = useEditor.getState().timelineH;
    startDrag(e, {
      onMove: (_dx, dy) => {
        const max = Math.min(TIMELINE_H_MAX, window.innerHeight - 220);
        useEditor.getState().setTimelineH(Math.min(max, h0 - dy));
      },
    });
  };

  return (
    <footer
      className="relative flex min-w-0 shrink-0 flex-col overflow-hidden border-t border-border bg-card"
      style={{ height: timelineH }}
      onDragOver={(e) => {
        if (hasAssetDrag(e)) {
          e.preventDefault();
          e.dataTransfer.dropEffect = "copy";
        }
      }}
      onDrop={(e) => {
        const id = draggedAssetId(e);
        if (!id) return;
        e.preventDefault();
        const s = useEditor.getState();
        const asset = s.assets.find((a) => a.id === id);
        if (!asset) return;
        if (asset.type === "video") s.addClipFromAsset(id);
        else s.addAudioFromAsset(id);
      }}
    >
      <div
        className="tl-resize absolute inset-x-0 top-0 z-30 h-1.5 cursor-row-resize"
        title="Drag to resize the timeline"
        onPointerDown={resize}
      />
      <div className="relative flex h-11 shrink-0 items-center gap-0.5 border-b border-border px-2.5">
        <Button
          variant="ghost"
          size="sm"
          title="Split at pointer, or at playhead (⌘B or S)"
          onClick={() => {
            const s = useEditor.getState();
            s.splitAtPlayhead(s.skimTime ?? undefined);
          }}
        >
          <Scissors /> Split
        </Button>
        <Button variant="ghost" size="sm" title="Title (T)" onClick={() => useEditor.getState().addOverlay()}>
          <Type /> Title
        </Button>
        <Button
          variant="ghost"
          size="sm"
          title="Delete (⌫)"
          disabled={!selection}
          onClick={() => useEditor.getState().deleteSelection()}
        >
          <Trash2 /> Delete
        </Button>

        <Transport total={total} />

        <div className="flex-1" />
        <Slider
          className="data-horizontal:w-28"
          min={12}
          max={800}
          value={pps}
          aria-label="Zoom"
          onValueChange={(v) => zoomTo(Number(v))}
        />
        <Button variant="ghost" size="sm" title="Fit timeline to window" onClick={fit}>
          Fit
        </Button>
      </div>

      <div ref={scrollRef} className="tl-scroll min-h-0 flex-1 overflow-x-auto overflow-y-hidden">
        <div className="h-full" style={{ width: contentW + PAD_SIDE * 2 }}>
          <div
            ref={innerRef}
            className="tl-content relative h-full pb-2"
            style={{ width: contentW, marginLeft: PAD_SIDE }}
          >
          <Ruler pps={pps} width={contentW} onScrub={scrub} />

          <div className="relative mt-1.5" style={{ height: VIDEO_H }} onPointerDown={deselectIfSelf}>
            {spans.length === 0 && (
              <div className="pointer-events-none sticky left-0 flex h-full w-[calc(100vw-40px)] max-w-[900px] items-center justify-center gap-1.5 rounded-xl border-[1.5px] border-dashed border-input text-xs font-medium text-muted-foreground">
                <Plus className="size-3.5" /> Add media to this project
              </div>
            )}
            {dragInfo && (
              <div
                className="tl-drop-slot pointer-events-none absolute top-0.5 rounded-lg bg-[#0a84ff]/10 shadow-[inset_0_0_0_1.5px_rgba(10,132,255,0.4),inset_0_2px_10px_rgba(10,60,140,0.08)] transition-[left] duration-150 ease-out"
                style={{
                  left: dragInfo.gapStart * pps,
                  width: Math.max(10, dragInfo.len * pps - CLIP_GAP),
                  height: VIDEO_H - 4,
                }}
              />
            )}
            {spans.map((span, i) => (
              <ClipView
                key={span.clip.id}
                span={span}
                index={i}
                pps={pps}
                selected={selection?.kind === "clip" && selection.id === span.clip.id}
                drag={dragInfo}
                scrollRef={scrollRef}
                onDrag={onClipDrag}
                onDrop={onClipDrop}
              />
            ))}
          </div>

          <div className="relative mt-1.5" style={{ height: AUDIO_H }} onPointerDown={deselectIfSelf}>
            {audioClips.length === 0 && (
              <TrackHint icon={<Music className="size-3" />} label="Soundtrack" />
            )}
            {audioClips.map((a) => (
              <AudioView
                key={a.id}
                clip={a}
                asset={assets.find((x) => x.id === a.assetId)}
                pps={pps}
                selected={selection?.kind === "audio" && selection.id === a.id}
              />
            ))}
          </div>

          <div className="relative mt-1.5" style={{ height: TEXT_H }} onPointerDown={deselectIfSelf}>
            {overlays.length === 0 && (
              <TrackHint icon={<Type className="size-3" />} label="Titles" />
            )}
            {overlays.map((o) => (
              <TextBar
                key={o.id}
                overlay={o}
                pps={pps}
                selected={selection?.kind === "text" && selection.id === o.id}
              />
            ))}
          </div>

          {subtitles.showOnTimeline && subtitles.cues.length > 0 && (
            <div
              className="tl-sub-track relative mt-1.5"
              style={{ height: SUB_H }}
              onPointerDown={deselectIfSelf}
            >
              {subtitles.cues.map((c) => (
                <SubBar key={c.id} cue={c} pps={pps} />
              ))}
            </div>
          )}

            <HoverLine scrollRef={scrollRef} innerRef={innerRef} pps={pps} />
            <Playhead pps={pps} scrollRef={scrollRef} onScrub={scrub} />
          </div>
        </div>
      </div>
    </footer>
  );
}

/**
 * iMovie skimmer: a line that follows the mouse over the timeline. It marks
 * where Split (⌘B / S) will cut; clicking still moves the playhead itself.
 */
function HoverLine({
  scrollRef,
  innerRef,
  pps,
}: {
  scrollRef: React.RefObject<HTMLDivElement | null>;
  innerRef: React.RefObject<HTMLDivElement | null>;
  pps: number;
}) {
  const skimTime = useEditor((s) => s.skimTime);
  useEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    const move = (e: PointerEvent) => {
      const inner = innerRef.current;
      const s = useEditor.getState();
      if (!inner || e.buttons) return s.setSkimTime(null);
      const t = (e.clientX - inner.getBoundingClientRect().left) / s.pxPerSec;
      s.setSkimTime(Math.max(0, t));
    };
    const leave = () => useEditor.getState().setSkimTime(null);
    el.addEventListener("pointermove", move);
    el.addEventListener("pointerleave", leave);
    return () => {
      el.removeEventListener("pointermove", move);
      el.removeEventListener("pointerleave", leave);
      useEditor.getState().setSkimTime(null);
    };
  }, [scrollRef, innerRef]);
  if (skimTime === null) return null;
  return (
    <div
      className="tl-hover-line pointer-events-none absolute top-0 bottom-2 z-6 w-px bg-foreground/30"
      style={{ transform: `translateX(${skimTime * pps}px)` }}
    />
  );
}

/** Playback transport, centered in the timeline toolbar. */
function Transport({ total }: { total: number }) {
  const playing = useEditor((s) => s.playing);
  const currentTime = useEditor((s) => s.currentTime);
  const hasClips = total > 0;

  const toggle = () => {
    const s = useEditor.getState();
    if (!s.playing && s.currentTime >= total - 0.01) s.seek(0);
    s.setPlaying(!s.playing);
  };

  return (
    <div className="absolute left-1/2 flex -translate-x-1/2 items-center gap-2">
      <Button
        variant="ghost"
        size="icon-sm"
        aria-label="Back to start"
        disabled={!hasClips}
        onClick={() => useEditor.getState().seek(0)}
      >
        <SkipBack className="fill-current" />
      </Button>
      <button
        className="grid size-8 place-items-center rounded-full bg-foreground text-background transition-transform hover:opacity-90 active:scale-95 disabled:opacity-40"
        title="Play/Pause (Space)"
        disabled={!hasClips}
        onClick={toggle}
      >
        {playing ? (
          <Pause className="size-4 fill-current stroke-none" />
        ) : (
          <Play className="ml-0.5 size-4 fill-current stroke-none" />
        )}
      </button>
      <div className="flex min-w-30 items-baseline gap-1.5 font-mono text-xs tabular-nums">
        <span className="tc-now">{formatTimecode(currentTime)}</span>
        <span className="text-muted-foreground">/</span>
        <span className="text-muted-foreground">{formatTimecode(total)}</span>
      </div>
    </div>
  );
}

function TrackHint({ icon, label }: { icon: React.ReactNode; label: string }) {
  return (
    <div className="pointer-events-none sticky left-0 inline-flex h-full items-center gap-1.5 px-4 text-[10.5px] font-semibold tracking-wider text-muted-foreground/70 uppercase">
      {icon} {label}
    </div>
  );
}

function Ruler({
  pps,
  width,
  onScrub,
}: {
  pps: number;
  width: number;
  onScrub: (e: React.PointerEvent) => void;
}) {
  const steps = [0.5, 1, 2, 5, 10, 15, 30, 60];
  const step = steps.find((s) => s * pps >= 64) ?? 120;
  const count = Math.ceil(width / (step * pps));
  const ticks = Array.from({ length: count }, (_, i) => i * step);
  return (
    <div className="relative h-[26px] cursor-ew-resize border-b border-border" onPointerDown={onScrub}>
      {ticks.map((t) => (
        <div
          key={t}
          className="absolute top-0 bottom-0 border-l border-foreground/15 pl-1.5"
          style={{ left: t * pps }}
        >
          <span className="font-mono text-[9.5px] leading-6 text-muted-foreground select-none">
            {formatTime(t)}
          </span>
        </div>
      ))}
    </div>
  );
}

function Playhead({
  pps,
  scrollRef,
  onScrub,
}: {
  pps: number;
  scrollRef: React.RefObject<HTMLDivElement | null>;
  onScrub: (e: React.PointerEvent) => void;
}) {
  const t = useEditor((s) => s.currentTime);
  const playing = useEditor((s) => s.playing);
  const x = t * pps;

  useEffect(() => {
    const el = scrollRef.current;
    if (!el || !playing) return;
    const sx = x + PAD_SIDE; // playhead position in scroll coordinates
    if (sx < el.scrollLeft + 24 || sx > el.scrollLeft + el.clientWidth - 80) {
      el.scrollLeft = Math.max(0, sx - 80);
    }
  }, [x, playing, scrollRef]);

  return (
    <div
      className="pointer-events-none absolute top-0 bottom-2 left-0 z-8 w-[1.5px] bg-[#0a84ff] shadow-[0_0_8px_rgba(10,132,255,0.6)]"
      style={{ transform: `translateX(${x}px)` }}
    >
      <div
        className="tl-playhead-cap pointer-events-auto absolute -top-0 -left-[7px] h-5 w-4 cursor-ew-resize"
        onPointerDown={onScrub}
      >
        <div className="mx-auto h-3 w-2.5 rounded-t-[3px] bg-[#0a84ff] [clip-path:polygon(0_0,100%_0,100%_58%,50%_100%,0_58%)]" />
      </div>
    </div>
  );
}

function ClipView({
  span,
  index,
  pps,
  selected,
  drag,
  scrollRef,
  onDrag,
  onDrop,
}: {
  span: ClipSpan;
  index: number;
  pps: number;
  selected: boolean;
  drag: ClipDrag | null;
  scrollRef: React.RefObject<HTMLDivElement | null>;
  onDrag: (id: string, dx: number, dy: number) => void;
  onDrop: (id: string, dx: number | null) => void;
}) {
  // Left-trim keeps the box and its frames pinned: the handle sweeps through
  // the clip and the leading area dims as "hidden"; release collapses it.
  const [trim, setTrim] = useState<{ side: "l"; in0: number } | { side: "r" } | null>(null);
  const { clip, asset } = span;
  const w = span.len * pps;
  const left = span.start * pps;
  const trimL = trim?.side === "l" ? trim : null;
  const stripIn = trimL ? Math.min(clip.in, trimL.in0) : clip.in;
  const hidPx = trimL ? Math.max(0, (clip.in - trimL.in0) * pps) : 0;
  const boxW = trimL ? (clip.out - stripIn) * pps : w;
  const isDragged = drag?.id === clip.id;
  // Neighbors part to make room for the open slot.
  const shiftSec =
    !drag || isDragged
      ? 0
      : drag.from < index && index <= drag.to
        ? -drag.len
        : drag.to <= index && index < drag.from
          ? drag.len
          : 0;

  // During a left-trim the strip is computed from the drag-start in-point so
  // every frame stays pinned in place while the hidden region sweeps over it.
  const filmstrip = useMemo(() => {
    if (!asset.thumbs?.length || !asset.thumbStep) return [];
    const aspect = (asset.width ?? 16) / Math.max(1, asset.height ?? 9);
    const imgW = Math.max(26, Math.round((VIDEO_H - 4) * aspect));
    const count = Math.min(120, Math.ceil(boxW / imgW));
    return Array.from({ length: count }, (_, k) => {
      const timeAt = stripIn + (k * imgW + imgW / 2) / pps;
      const idx = Math.min(
        asset.thumbs!.length - 1,
        Math.max(0, Math.floor(timeAt / asset.thumbStep!))
      );
      return { src: asset.thumbs![idx], left: k * imgW, width: imgW };
    });
  }, [asset, stripIn, boxW, pps]);

  const onBody = (e: React.PointerEvent) => {
    const s = useEditor.getState();
    s.select({ kind: "clip", id: clip.id });
    // Clicking anywhere on the timeline moves the playhead — clips included.
    const rect = e.currentTarget.getBoundingClientRect();
    s.seek(span.start + (e.clientX - rect.left) / pps);
    const el = scrollRef.current;
    const sc0 = el?.scrollLeft ?? 0;
    let effDx = 0;
    let live = false;
    startDrag(e, {
      onMove: (dx, dy, ev) => {
        if (!live && Math.abs(dx) < 4 && Math.abs(dy) < 4) return;
        live = true;
        if (el) {
          const r = el.getBoundingClientRect();
          if (ev.clientX > r.right - 36) el.scrollLeft += 14;
          else if (ev.clientX < r.left + 36) el.scrollLeft -= 14;
        }
        effDx = dx + ((el?.scrollLeft ?? sc0) - sc0);
        onDrag(clip.id, effDx, Math.max(-26, Math.min(14, dy)));
      },
      onUp: () => onDrop(clip.id, live ? effDx : null),
    });
  };

  const onTrimLeft = (e: React.PointerEvent) => {
    const s = useEditor.getState();
    s.select({ kind: "clip", id: clip.id });
    s.pushHistory();
    const in0 = clip.in;
    setTrim({ side: "l", in0 });
    startDrag(e, {
      onMove: (dx) => {
        const nin = Math.min(clip.out - 0.15, Math.max(0, in0 + dx / pps));
        s.updateClipTransient(clip.id, { in: nin });
      },
      onUp: () => setTrim(null),
    });
  };

  const onTrimRight = (e: React.PointerEvent) => {
    const s = useEditor.getState();
    s.select({ kind: "clip", id: clip.id });
    s.pushHistory();
    setTrim({ side: "r" });
    const out0 = clip.out;
    startDrag(e, {
      onMove: (dx) => {
        const nout = Math.max(clip.in + 0.15, Math.min(asset.duration, out0 + dx / pps));
        s.updateClipTransient(clip.id, { out: nout });
      },
      onUp: () => setTrim(null),
    });
  };

  return (
    <>
      <div
        className={cn(
          "tl-clip group absolute top-0.5 cursor-grab overflow-hidden rounded-lg bg-neutral-200 shadow-[inset_0_0_0_1px_rgba(0,0,0,0.12)]",
          selected && SELECTED_SHADOW,
          isDragged
            ? "tl-clip-ghost pointer-events-none z-7 cursor-grabbing opacity-80 shadow-2xl"
            : drag && "transition-transform duration-150 ease-out"
        )}
        style={{
          left,
          width: Math.max(10, boxW - CLIP_GAP),
          height: VIDEO_H - 4,
          transform: isDragged
            ? `translate(${drag!.dx}px, ${drag!.dy}px)`
            : shiftSec !== 0
              ? `translateX(${shiftSec * pps}px)`
              : undefined,
        }}
        onPointerDown={onBody}
      >
        <div className="tl-filmstrip pointer-events-none absolute inset-0">
          {filmstrip.map((f, k) => (
            // eslint-disable-next-line @next/next/no-img-element
            <img
              key={k}
              src={f.src}
              alt=""
              draggable={false}
              className="absolute top-0 h-full object-cover"
              style={{ left: f.left, width: f.width }}
            />
          ))}
        </div>
        {hidPx > 0 && (
          <div
            className="tl-trim-hidden pointer-events-none absolute inset-y-0 left-0 z-2 border-r border-white/70 bg-black/55"
            style={{ width: hidPx }}
          />
        )}
        {(isDragged || trim !== null) && (
          <span
            className="tl-dur-chip pointer-events-none absolute top-1 z-2 rounded-[5px] bg-black/65 px-1.5 py-px font-mono text-[10px] tabular-nums text-white"
            style={{ left: hidPx + 4 }}
          >
            {(Math.round(span.len * 10) / 10).toFixed(1)}s
          </span>
        )}
        {clip.muted && (
          <span className="tl-mute-chip absolute bottom-1 left-1 z-2 grid size-[18px] place-items-center rounded-[5px] bg-black/70 text-white" title="Muted">
            <VolumeX className="size-3" />
          </span>
        )}
        <DropdownMenu>
          <DropdownMenuTrigger
            render={
              <button
                aria-label="Clip options"
                className="tl-clip-menu absolute top-1 right-2 z-4 grid size-[18px] place-items-center rounded-[5px] bg-black/55 text-white opacity-0 transition-opacity group-hover:opacity-100 hover:bg-black/75"
                onPointerDown={(e) => e.stopPropagation()}
              />
            }
          >
            <EllipsisVertical className="size-3" />
          </DropdownMenuTrigger>
          <DropdownMenuContent align="start" className="w-44">
            <DropdownMenuItem
              disabled={clip.muted}
              onClick={() => {
                const s = useEditor.getState();
                s.select({ kind: "clip", id: clip.id });
                s.detachAudio();
                void ensurePeaks(asset);
              }}
            >
              <AudioLines /> Detach audio
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
        <span
          className={cn(trimHandle, "tl-trim-l", trim?.side === "l" && "z-3 after:opacity-100")}
          style={{ left: hidPx }}
          onPointerDown={onTrimLeft}
        />
        <span
          className={cn(trimHandle, "tl-trim-r right-0", trim?.side === "r" && "after:opacity-100")}
          onPointerDown={onTrimRight}
        />
      </div>
      {trim !== null && (
        <div
          className="tl-trim-tip pointer-events-none absolute z-9 -translate-x-1/2 rounded-md bg-foreground px-1.5 py-0.5 font-mono text-[10px] tabular-nums text-background shadow-md"
          style={{
            left: trim.side === "l" ? left + hidPx : left + Math.max(10, w - CLIP_GAP),
            top: -24,
          }}
        >
          {formatTimecode(trim.side === "l" ? clip.in : clip.out)}
        </div>
      )}
    </>
  );
}

function AudioView({
  clip,
  asset,
  pps,
  selected,
}: {
  clip: AudioClip;
  asset: MediaAsset | undefined;
  pps: number;
  selected: boolean;
}) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const len = clipLen(clip);
  const w = Math.max(10, len * pps);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas || !asset?.peaks) return;
    const width = Math.min(4000, Math.round(w));
    const height = AUDIO_H - 8;
    canvas.width = width;
    canvas.height = height;
    const ctx = canvas.getContext("2d")!;
    ctx.clearRect(0, 0, width, height);
    ctx.fillStyle = "rgba(255, 255, 255, 0.85)";
    const peaks = asset.peaks;
    const n = peaks.length;
    const from = (clip.in / asset.duration) * n;
    const span = ((clip.out - clip.in) / asset.duration) * n;
    const bars = Math.max(1, Math.floor(width / 3));
    for (let i = 0; i < bars; i++) {
      const p = peaks[Math.min(n - 1, Math.floor(from + (i / bars) * span))] ?? 0;
      const h = Math.max(1.5, p * (height - 2));
      ctx.fillRect(i * 3, (height - h) / 2, 2, h);
    }
  }, [asset, clip.in, clip.out, w]);

  if (!asset) return null;

  const onBody = (e: React.PointerEvent) => {
    const s = useEditor.getState();
    s.select({ kind: "audio", id: clip.id });
    s.seek(clip.start + (e.clientX - e.currentTarget.getBoundingClientRect().left) / pps);
    s.pushHistory();
    const start0 = clip.start;
    startDrag(e, {
      onMove: (dx) =>
        s.updateAudioTransient(clip.id, { start: Math.max(0, start0 + dx / pps) }),
    });
  };

  const onTrimLeft = (e: React.PointerEvent) => {
    const s = useEditor.getState();
    s.select({ kind: "audio", id: clip.id });
    s.pushHistory();
    const in0 = clip.in;
    const start0 = clip.start;
    startDrag(e, {
      onMove: (dx) => {
        let d = dx / pps;
        d = Math.max(d, -in0, -start0);
        d = Math.min(d, clip.out - 0.15 - in0);
        s.updateAudioTransient(clip.id, { in: in0 + d, start: start0 + d });
      },
    });
  };

  const onTrimRight = (e: React.PointerEvent) => {
    const s = useEditor.getState();
    s.select({ kind: "audio", id: clip.id });
    s.pushHistory();
    const out0 = clip.out;
    startDrag(e, {
      onMove: (dx) => {
        const nout = Math.max(clip.in + 0.15, Math.min(asset.duration, out0 + dx / pps));
        s.updateAudioTransient(clip.id, { out: nout });
      },
    });
  };

  return (
    <div
      className={cn(
        "tl-audio-clip group absolute top-0.5 cursor-grab overflow-hidden rounded-[7px] bg-gradient-to-b from-emerald-500 to-emerald-600 shadow-[inset_0_0_0_1px_rgba(0,0,0,0.1)]",
        selected && SELECTED_SHADOW
      )}
      style={{ left: clip.start * pps, width: w, height: AUDIO_H - 4 }}
      onPointerDown={onBody}
    >
      <canvas ref={canvasRef} className="pointer-events-none absolute inset-x-0 inset-y-1" />
      {(clip.fadeIn ?? 0) > 0 && (
        <div
          className="tl-fade-in pointer-events-none absolute inset-y-0 left-0 bg-gradient-to-r from-black/45 to-transparent"
          style={{ width: Math.min(w, (clip.fadeIn ?? 0) * pps) }}
        />
      )}
      {(clip.fadeOut ?? 0) > 0 && (
        <div
          className="tl-fade-out pointer-events-none absolute inset-y-0 right-0 bg-gradient-to-l from-black/45 to-transparent"
          style={{ width: Math.min(w, (clip.fadeOut ?? 0) * pps) }}
        />
      )}
      <span className="pointer-events-none absolute top-[3px] left-2 text-[9.5px] whitespace-nowrap text-white/90 [text-shadow:0_1px_2px_rgba(0,0,0,0.35)]">
        {asset.name}
      </span>
      <span className={cn(trimHandle, "tl-trim-l left-0")} onPointerDown={onTrimLeft} />
      <span className={cn(trimHandle, "tl-trim-r right-0")} onPointerDown={onTrimRight} />
    </div>
  );
}

function TextBar({
  overlay: o,
  pps,
  selected,
}: {
  overlay: TextOverlay;
  pps: number;
  selected: boolean;
}) {
  const w = Math.max(8, (o.end - o.start) * pps);

  const onBody = (e: React.PointerEvent) => {
    const s = useEditor.getState();
    s.select({ kind: "text", id: o.id });
    s.pushHistory();
    const start0 = o.start;
    const len = o.end - o.start;
    startDrag(e, {
      onMove: (dx) => {
        const start = Math.max(0, start0 + dx / pps);
        s.updateOverlayTransient(o.id, { start, end: start + len });
      },
    });
  };

  const onTrimLeft = (e: React.PointerEvent) => {
    const s = useEditor.getState();
    s.select({ kind: "text", id: o.id });
    s.pushHistory();
    const start0 = o.start;
    startDrag(e, {
      onMove: (dx) => {
        const start = Math.min(o.end - 0.2, Math.max(0, start0 + dx / pps));
        s.updateOverlayTransient(o.id, { start });
      },
    });
  };

  const onTrimRight = (e: React.PointerEvent) => {
    const s = useEditor.getState();
    s.select({ kind: "text", id: o.id });
    s.pushHistory();
    const end0 = o.end;
    startDrag(e, {
      onMove: (dx) => {
        const end = Math.max(o.start + 0.2, end0 + dx / pps);
        s.updateOverlayTransient(o.id, { end });
      },
    });
  };

  return (
    <div
      className={cn(
        "tl-text-bar group absolute top-0.5 flex cursor-grab items-center overflow-hidden rounded-md bg-gradient-to-b from-purple-500 to-purple-600 shadow-[inset_0_0_0_1px_rgba(0,0,0,0.1)]",
        selected && SELECTED_SHADOW
      )}
      style={{ left: o.start * pps, width: w, height: TEXT_H - 6 }}
      onPointerDown={onBody}
    >
      <span className="pointer-events-none truncate px-2 text-[10.5px] font-medium text-white">
        {o.text.replace(/\n/g, " ")}
      </span>
      <span className={cn(trimHandle, "tl-trim-l left-0")} onPointerDown={onTrimLeft} />
      <span className={cn(trimHandle, "tl-trim-r right-0")} onPointerDown={onTrimRight} />
    </div>
  );
}

/** A subtitle cue on its track: drag to retime, edges to trim, click seeks.
 * Editing the words happens in the Subtitles panel. */
function SubBar({ cue, pps }: { cue: SubtitleCue; pps: number }) {
  const w = Math.max(8, (cue.end - cue.start) * pps);

  const finish = (moved: boolean) => {
    const s = useEditor.getState();
    if (moved) s.sortCues();
    else s.seek(cue.start + 0.001);
  };

  const onBody = (e: React.PointerEvent) => {
    const s = useEditor.getState();
    s.pushHistory();
    const start0 = cue.start;
    const len = cue.end - cue.start;
    startDrag(e, {
      onMove: (dx) => {
        const start = Math.max(0, start0 + dx / pps);
        // Moving a cue detaches it from its word timings.
        s.updateCueTransient(cue.id, { start, end: start + len, words: undefined });
      },
      onUp: (_dx, _dy, moved) => finish(moved),
    });
  };

  const trim = (side: "l" | "r") => (e: React.PointerEvent) => {
    const s = useEditor.getState();
    s.pushHistory();
    const { start: start0, end: end0 } = cue;
    startDrag(e, {
      onMove: (dx) => {
        if (side === "l")
          s.updateCueTransient(cue.id, {
            start: Math.min(end0 - 0.15, Math.max(0, start0 + dx / pps)),
            words: undefined,
          });
        else
          s.updateCueTransient(cue.id, {
            end: Math.max(start0 + 0.15, end0 + dx / pps),
            words: undefined,
          });
      },
      onUp: (_dx, _dy, moved) => finish(moved),
    });
  };

  return (
    <div
      className="tl-sub-bar group absolute top-px flex cursor-grab items-center overflow-hidden rounded-[5px] bg-gradient-to-b from-amber-300 to-amber-400 shadow-[inset_0_0_0_1px_rgba(0,0,0,0.12)]"
      style={{ left: cue.start * pps, width: w, height: SUB_H - 4 }}
      title={cue.text}
      onPointerDown={onBody}
    >
      <span className="pointer-events-none truncate px-1.5 text-[9.5px] font-medium text-amber-950/90">
        {cue.text}
      </span>
      <span className={cn(trimHandle, "tl-trim-l left-0")} onPointerDown={trim("l")} />
      <span className={cn(trimHandle, "tl-trim-r right-0")} onPointerDown={trim("r")} />
    </div>
  );
}
