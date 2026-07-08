"use client";

import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { AudioLines, Blend, Check, EllipsisVertical, FolderPlus, Loader2, Pause, Play, Plus, Scissors, SkipBack, Trash2, Type, VolumeX } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Slider } from "@/components/ui/slider";
import {
  clearAssetDrag,
  draggedAssetId,
  draggedLibraryId,
  draggingAssetId,
  draggingLibrary,
  hasAssetDrag,
  hasLibraryDrag,
} from "@/cut/lib/assetDrag";
import { importLibraryAsset, saveTemplate } from "@/cut/lib/library";
import { startDrag } from "@/cut/lib/drag";
import { ensurePeaks } from "@/cut/lib/media";
import { clipLen, clipSpeed, getClipSpans, projectDuration, TIMELINE_H_MAX, useEditor } from "@/cut/lib/store";
import type { VideoTrackPlacement } from "@/cut/lib/store";
import { formatTime, formatTimecode } from "@/cut/lib/time";
import type { AudioClip, ClipSpan, MediaAsset, OverlayClip, SubtitleCue, TextOverlay } from "@/cut/lib/types";
import { cn } from "@/lib/utils";

const VIDEO_H = 64;
const OVERLAY_H = VIDEO_H; // upper video tracks match the base row height
const AUDIO_H = 44;

/** Where a dragged video clip can land. Re-exported name for the store's
 * placement union (existing track / base row / newly-inserted track). */
type TrackTarget = VideoTrackPlacement;

/** Encode/decode a placement in a row's `data-drop` attribute. */
function placementAttr(place: TrackTarget): string {
  return place.kind === "base"
    ? "base"
    : place.kind === "track"
      ? `track:${place.track}`
      : `insert:${place.level}`;
}
function parsePlacement(raw: string): TrackTarget | null {
  if (raw === "base") return { kind: "base" };
  const [k, n] = raw.split(":");
  if (k === "track") return { kind: "track", track: Number(n) };
  if (k === "insert") return { kind: "insert", level: Number(n) };
  return null;
}
/** Two placements point at the same drop. */
function samePlacement(a: TrackTarget | null, b: TrackTarget | null): boolean {
  if (!a || !b || a.kind !== b.kind) return false;
  return a.kind === "track"
    ? a.track === (b as { track: number }).track
    : a.kind === "insert"
      ? a.level === (b as { level: number }).level
      : true;
}
const TEXT_H = 28;
const SUB_H = 22;
const PAD_END = 320;
/** Breathing room on both sides so the playhead cap is never clipped. */
const PAD_SIDE = 20;
/** Visual gutter between adjacent clips (iMovie); time math stays exact. */
const CLIP_GAP = 4;

// A high-contrast selected state: a bright blue ring drawn both inside and
// (crucially) *outside* the box, so it stays visible on top of a clip's
// filmstrip thumbnails, plus a halo and a raised stacking order so selected
// items read clearly against their neighbours.
const SELECTED_SHADOW =
  "z-10 shadow-[inset_0_0_0_2px_#0a84ff,0_0_0_2px_#0a84ff,0_2px_11px_rgba(10,132,255,0.6)]";

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

/** Insertion slot for a new clip dropped at time `t`: it lands before the
 * first span whose midpoint is past `t` (spans.length = at the very end). */
function videoInsertIndex(spans: ClipSpan[], t: number): number {
  for (let k = 0; k < spans.length; k++) if (t < spans[k].start + spans[k].len / 2) return k;
  return spans.length;
}

export function Timeline() {
  const clips = useEditor((s) => s.clips);
  const audioClips = useEditor((s) => s.audioClips);
  const overlayClips = useEditor((s) => s.overlayClips);
  const overlays = useEditor((s) => s.overlays);
  const assets = useEditor((s) => s.assets);
  const pps = useEditor((s) => s.pxPerSec);
  const timelineH = useEditor((s) => s.timelineH);
  const multiSelection = useEditor((s) => s.multiSelection);
  const subtitles = useEditor((s) => s.subtitles);
  const scrollRef = useRef<HTMLDivElement>(null);
  const innerRef = useRef<HTMLDivElement>(null);
  // Measured width of the scroll viewport, so the ruler and tracks always draw
  // end-to-end no matter how wide the window is.
  const [viewportW, setViewportW] = useState(900);

  // Membership set so every track can highlight all selected items, not just
  // the primary one.
  const selKeys = useMemo(
    () => new Set(multiSelection.map((x) => (x ? `${x.kind}:${x.id}` : ""))),
    [multiSelection]
  );

  const spans = useMemo(() => getClipSpans(clips, assets), [clips, assets]);
  const total = projectDuration({ clips, overlayClips, audioClips });
  // Fill the viewport at minimum so a wide window never leaves the ruler/tracks
  // cut off; grow past it once the content is longer.
  const contentW = Math.max(total * pps + PAD_END, viewportW - PAD_SIDE * 2, 600);

  // Reorder drag on the video track: neighbors part to open a highlighted
  // slot at the insertion point; releasing drops the clip into it.
  const [clipDrag, setClipDrag] = useState<{ id: string; dx: number; dy: number } | null>(null);
  // Insertion preview while dragging a media asset onto the video track:
  // `index` is the span it lands before (spans.length = end), `len` its length.
  const [assetDrop, setAssetDrop] = useState<{ index: number; len: number } | null>(null);
  // Kind of external media being dragged over the timeline (audio vs video).
  const [dropType, setDropType] = useState<"video" | "audio" | null>(null);
  // A video clip is being dragged (internal or external): reveals the
  // between-track insertion zones so a drop can open a brand-new track anywhere.
  const [videoDragging, setVideoDragging] = useState(false);
  // The pending drop preview: which track/gap, at what time, for how long.
  const [overlayDrop, setOverlayDrop] = useState<
    { target: TrackTarget; t: number; len: number } | null
  >(null);
  const insertMode = videoDragging || dropType === "video";
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

  // Which drop the cursor is over: an upper track, the base row, or a gap
  // between/above/below tracks that would open a new one. Hit-test live via
  // elementFromPoint — rows and gap zones carry a `data-drop` placement.
  const resolveDropTrack = useCallback((clientX: number, clientY: number): TrackTarget => {
    const el = document.elementFromPoint(clientX, clientY) as HTMLElement | null;
    const zone = el?.closest<HTMLElement>("[data-drop]");
    const parsed = zone ? parsePlacement(zone.dataset.drop!) : null;
    if (parsed) return parsed;
    // Past the ends of the stack → a new track beyond the last one.
    const rows = innerRef.current?.querySelectorAll<HTMLElement>("[data-drop]");
    const tracks = useEditor.getState().overlayClips.map((c) => c.track);
    if (rows && rows.length) {
      if (clientY < rows[0].getBoundingClientRect().top)
        return { kind: "insert", level: Math.max(0, ...tracks) + 1 };
      if (clientY > rows[rows.length - 1].getBoundingClientRect().bottom)
        return { kind: "insert", level: Math.min(0, ...tracks) - 1 };
    }
    return { kind: "base" };
  }, []);

  // Drive the drop preview while a clip is dragged across tracks: highlight the
  // target track, base slot, or a between-track insertion line.
  const previewCross = useCallback((target: TrackTarget | null, start = 0, len = 0) => {
    if (target === null) return setOverlayDrop(null);
    setClipDrag(null);
    setOverlayDrop({ target, t: start, len });
  }, []);

  // Releasing a base clip anywhere but the base row lifts it out onto that track
  // (or a new one); the base row itself is a plain reorder (via onClipDrop).
  const onBaseCrossDrop = useCallback(
    (id: string, target: TrackTarget, start: number) => {
      previewCross(null);
      if (target.kind === "base") return;
      useEditor.getState().dropVideoClip({ kind: "base", id }, target, start);
    },
    [previewCross]
  );

  // Releasing an overlay clip anywhere: another track, a new inserted track, or
  // down into the base row.
  const onOverlayCrossDrop = useCallback(
    (id: string, target: TrackTarget, start: number) => {
      previewCross(null);
      useEditor.getState().dropVideoClip({ kind: "overlay", id }, target, start);
    },
    [previewCross]
  );

  // Title tracks: overlays carry a `lane`; used lanes compact to contiguous
  // display rows, so empty tracks disappear on their own.
  const [textDrag, setTextDrag] = useState<{ id: string; targetRow: number } | null>(null);
  const overlayLanes = useMemo(() => {
    const used = [...new Set(overlays.map((o) => o.lane ?? 0))].sort((a, b) => a - b);
    const rowOf = new Map(used.map((l, i) => [l, i]));
    return { used, rowOf, count: used.length };
  }, [overlays]);

  // Video tracks either side of the base: positive tracks (PiP / composited
  // layers) render above the base, negative ones below it as a backdrop. Both
  // list highest-first (nearest the base at the inner edge); empty tracks vanish.
  const aboveTracks = useMemo(
    () => [...new Set(overlayClips.map((c) => c.track).filter((n) => n > 0))].sort((a, b) => b - a),
    [overlayClips]
  );
  const belowTracks = useMemo(
    () => [...new Set(overlayClips.map((c) => c.track).filter((n) => n < 0))].sort((a, b) => b - a),
    [overlayClips]
  );

  const onTextLaneDrag = useCallback(
    (id: string, targetRow: number) => setTextDrag({ id, targetRow }),
    []
  );
  const onTextLaneDrop = useCallback((id: string, targetRow: number) => {
    setTextDrag(null);
    const s = useEditor.getState();
    const used = [...new Set(s.overlays.map((o) => o.lane ?? 0))].sort((a, b) => a - b);
    const cur = s.overlays.find((o) => o.id === id);
    if (!cur) return;
    const curRow = used.indexOf(cur.lane ?? 0);
    if (targetRow === curRow) return;
    // A row past the end becomes a brand-new track above the current max.
    const lane = targetRow < used.length ? used[targetRow] : (used[used.length - 1] ?? -1) + 1;
    s.moveOverlayToLane(id, lane);
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
    const dur = projectDuration(useEditor.getState());
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
        // When the tracks overflow vertically, let the wheel scroll them;
        // otherwise map vertical wheel to horizontal panning (the timeline is
        // mostly wide).
        if (el.scrollHeight <= el.clientHeight) {
          e.preventDefault();
          el.scrollLeft += e.deltaY;
        }
      }
    };
    el.addEventListener("wheel", onWheel, { passive: false });
    return () => el.removeEventListener("wheel", onWheel);
  }, [zoomTo]);

  // Track the viewport width so `contentW` can fill it end-to-end.
  useEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    const measure = () => setViewportW(el.clientWidth);
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

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
        s.seek(projectDuration(s));
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [zoomTo]);

  // Drop an asset onto the timeline: video snaps into the nearest slot at time
  // `t`, audio lands free-form there.
  const placeAssetAt = (assetId: string, type: "video" | "audio", t: number) => {
    const s = useEditor.getState();
    if (type === "video") {
      const sp = getClipSpans(s.clips, s.assets);
      const spanIndex = videoInsertIndex(sp, t);
      const clipsIndex =
        spanIndex < sp.length
          ? s.clips.findIndex((c) => c.id === sp[spanIndex].clip.id)
          : s.clips.length;
      s.addClipFromAsset(assetId, clipsIndex);
    } else {
      s.addAudioFromAsset(assetId, t);
    }
  };

  // The video being dragged, whether it comes from project media or the library.
  const draggedVideo = (e: React.DragEvent): { duration: number } | null => {
    if (hasLibraryDrag(e)) {
      const lib = draggingLibrary();
      return lib && lib.type === "video" ? { duration: lib.duration } : null;
    }
    const id = draggingAssetId();
    const asset = id ? useEditor.getState().assets.find((a) => a.id === id) : null;
    return asset && asset.type === "video" ? { duration: asset.duration } : null;
  };

  // Drop targets for the upper tracks and between-track gaps: dragging a video
  // onto a lane adds it there; onto a gap opens a fresh track at that z-level.
  // Works the same for project media and library clips.
  const overlayDropHandlers = (place: TrackTarget) => ({
    onDragOver: (e: React.DragEvent) => {
      const vid = draggedVideo(e);
      if (!vid) return;
      e.preventDefault();
      e.stopPropagation();
      e.dataTransfer.dropEffect = "copy";
      setAssetDrop(null);
      setDropType("video"); // keep the insertion zones lit however the drag entered
      setOverlayDrop({ target: place, t: Math.max(0, timeAt(e.clientX)), len: vid.duration });
    },
    onDragLeave: (e: React.DragEvent) => {
      if (!e.currentTarget.contains(e.relatedTarget as Node | null)) setOverlayDrop(null);
    },
    onDrop: (e: React.DragEvent) => {
      e.preventDefault();
      e.stopPropagation();
      const t = Math.max(0, timeAt(e.clientX));
      setOverlayDrop(null);
      setDropType(null);
      const lib = draggingLibrary();
      const libId = draggedLibraryId(e);
      const projectId = useEditor.getState().projectId;
      clearAssetDrag();
      if (libId && lib && lib.type === "video" && projectId) {
        void importLibraryAsset(projectId, lib)
          .then((asset) => useEditor.getState().addVideoFromAsset(asset.id, place, t))
          .catch(() => {});
        return;
      }
      const id = draggedAssetId(e);
      const asset = id ? useEditor.getState().assets.find((a) => a.id === id) : null;
      if (id && asset?.type === "video") {
        useEditor.getState().addVideoFromAsset(id, place, t);
      }
    },
  });

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

  // A thin drop line in the gap above (or below) a track row: dropping here opens
  // a brand new track at z-level `level`. Straddles the gap so a drop near a row
  // edge inserts, while the row's middle still lands on that track.
  const insertZone = (level: number, side: "top" | "bottom" = "top") => {
    const active = samePlacement(overlayDrop?.target ?? null, { kind: "insert", level });
    return (
      <div
        data-drop={`insert:${level}`}
        className={cn(
          "absolute inset-x-0 z-20 flex h-[18px] items-center",
          side === "top" ? "-top-[9px]" : "-bottom-[9px]"
        )}
        {...overlayDropHandlers({ kind: "insert", level })}
      >
        <div
          className={cn(
            "h-[3px] w-full rounded-full transition-colors",
            active ? "bg-[#0a84ff]" : "bg-[#0a84ff]/25"
          )}
        />
      </div>
    );
  };

  return (
    <footer
      className="relative flex min-w-0 shrink-0 flex-col overflow-hidden border-t border-border bg-card select-none"
      style={{ height: timelineH }}
      onDragOver={(e) => {
        const isLib = hasLibraryDrag(e);
        if (!hasAssetDrag(e) && !isLib) return;
        e.preventDefault();
        e.dataTransfer.dropEffect = "copy";
        // Preview where a video would land; audio drops free-form. Library drags
        // carry their own shape since they aren't in the project yet.
        let type: "video" | "audio" | undefined;
        let duration = 0;
        if (isLib) {
          const lib = draggingLibrary();
          type = lib?.type;
          duration = lib?.duration ?? 0;
        } else {
          const id = draggingAssetId();
          const asset = id ? useEditor.getState().assets.find((a) => a.id === id) : null;
          type = asset?.type;
          duration = asset?.duration ?? 0;
        }
        setDropType(type ?? null);
        if (type !== "video" || !duration) {
          setAssetDrop(null);
          return;
        }
        const index = videoInsertIndex(spans, Math.max(0, timeAt(e.clientX)));
        setAssetDrop((prev) =>
          prev && prev.index === index && prev.len === duration ? prev : { index, len: duration }
        );
      }}
      onDragLeave={(e) => {
        if (!e.currentTarget.contains(e.relatedTarget as Node | null)) {
          setAssetDrop(null);
          setOverlayDrop(null);
          setDropType(null);
        }
      }}
      onDrop={(e) => {
        setAssetDrop(null);
        setOverlayDrop(null);
        setDropType(null);
        const t = Math.max(0, timeAt(e.clientX));

        // A library asset must be copied into the project before it can land.
        const lib = draggingLibrary();
        const libId = draggedLibraryId(e);
        const projectId = useEditor.getState().projectId;
        clearAssetDrag();
        if (libId && lib && projectId) {
          e.preventDefault();
          void importLibraryAsset(projectId, lib)
            .then((asset) => placeAssetAt(asset.id, asset.type, t))
            .catch(() => {});
          return;
        }

        const id = draggedAssetId(e);
        if (!id) return;
        e.preventDefault();
        const asset = useEditor.getState().assets.find((a) => a.id === id);
        if (asset) placeAssetAt(id, asset.type, t);
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
        <Button variant="ghost" size="sm" title="Text (T)" onClick={() => useEditor.getState().addOverlay()}>
          <Type /> Text
        </Button>
        <Button
          variant="ghost"
          size="sm"
          title="Delete (⌫)"
          disabled={multiSelection.length === 0}
          onClick={() => useEditor.getState().deleteSelection()}
        >
          <Trash2 /> {multiSelection.length > 1 ? `Delete ${multiSelection.length}` : "Delete"}
        </Button>
        <SaveSelectionButton />

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

      <div ref={scrollRef} className="tl-scroll min-h-0 flex-1 overflow-auto">
        <div className="flex min-h-full flex-col" style={{ width: contentW + PAD_SIDE * 2 }}>
          <div
            ref={innerRef}
            className="tl-content relative flex-1 pb-2"
            style={{ width: contentW, marginLeft: PAD_SIDE }}
            onPointerDown={deselectIfSelf}
          >
          <Ruler pps={pps} width={contentW} onScrub={scrub} />

          {aboveTracks.map((track) => (
            <div
              key={`ov-${track}`}
              className="relative mt-1.5"
              style={{ height: OVERLAY_H }}
              data-drop={placementAttr({ kind: "track", track })}
              onPointerDown={deselectIfSelf}
              {...overlayDropHandlers({ kind: "track", track })}
            >
              {insertMode && insertZone(track + 1)}
              {overlayClips
                .filter((c) => c.track === track)
                .map((c) => (
                  <OverlayClipView
                    key={c.id}
                    clip={c}
                    asset={assets.find((x) => x.id === c.assetId)}
                    pps={pps}
                    selected={selKeys.has(`overlayClip:${c.id}`)}
                    resolveTarget={resolveDropTrack}
                    onCrossMove={previewCross}
                    onCrossDrop={onOverlayCrossDrop}
                    onDragActive={setVideoDragging}
                  />
                ))}
              {samePlacement(overlayDrop?.target ?? null, { kind: "track", track }) && (
                <div
                  className="pointer-events-none absolute top-0.5 rounded-lg border-[1.5px] border-dashed border-[#0a84ff]/70 bg-[#0a84ff]/10"
                  style={{
                    left: overlayDrop!.t * pps,
                    width: Math.max(10, overlayDrop!.len * pps - CLIP_GAP),
                    height: OVERLAY_H - 4,
                  }}
                />
              )}
            </div>
          ))}

          <div
            className="relative mt-1.5"
            style={{ height: VIDEO_H }}
            data-drop="base"
            onPointerDown={deselectIfSelf}
          >
            {insertMode && insertZone(1)}
            {insertMode && insertZone(-1, "bottom")}
            {spans.length === 0 && (
              <div className="pointer-events-none sticky left-0 flex h-full w-[calc(100vw-40px)] max-w-[900px] items-center justify-center gap-1.5 rounded-xl border-[1.5px] border-dashed border-input text-xs font-medium text-muted-foreground">
                <Plus className="size-3.5" /> Add media to this project
              </div>
            )}
            {samePlacement(overlayDrop?.target ?? null, { kind: "base" }) && (
              <div
                className="pointer-events-none absolute top-0.5 rounded-lg border-[1.5px] border-dashed border-[#0a84ff]/70 bg-[#0a84ff]/10"
                style={{
                  left: overlayDrop!.t * pps,
                  width: Math.max(10, overlayDrop!.len * pps - CLIP_GAP),
                  height: VIDEO_H - 4,
                }}
              />
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
            {assetDrop && (
              <div
                className="tl-asset-drop-slot pointer-events-none absolute top-0.5 flex items-center justify-center rounded-lg border-[1.5px] border-dashed border-[#0a84ff]/70 bg-[#0a84ff]/10 text-[#0a84ff] transition-[left] duration-150 ease-out"
                style={{
                  left: (assetDrop.index < spans.length ? spans[assetDrop.index].start : total) * pps,
                  width: Math.max(10, assetDrop.len * pps - CLIP_GAP),
                  height: VIDEO_H - 4,
                }}
              >
                <Plus className="size-4" />
              </div>
            )}
            {spans.map((span, i) => (
              <ClipView
                key={span.clip.id}
                span={span}
                index={i}
                pps={pps}
                selected={selKeys.has(`clip:${span.clip.id}`)}
                drag={dragInfo}
                insertAtIndex={assetDrop ? assetDrop.index : null}
                insertLen={assetDrop ? assetDrop.len : 0}
                scrollRef={scrollRef}
                onDrag={onClipDrag}
                onDrop={onClipDrop}
                resolveTarget={resolveDropTrack}
                onCrossMove={previewCross}
                onCrossDrop={onBaseCrossDrop}
                onDragActive={setVideoDragging}
              />
            ))}
            {/* Cross-dissolve markers sit over the overlap between two clips. */}
            {!clipDrag &&
              spans.map((span) =>
                span.transitionOut > 0 ? (
                  <div
                    key={`xf-${span.clip.id}`}
                    className="tl-xfade pointer-events-none absolute z-6 flex -translate-x-1/2 items-center justify-center rounded-full bg-[#0a84ff] text-white shadow-[0_0_0_2px_rgba(255,255,255,0.9)]"
                    style={{
                      left: (span.start + span.len - span.transitionOut / 2) * pps,
                      top: (VIDEO_H - 4) / 2 - 8,
                      width: 16,
                      height: 16,
                    }}
                    title={`Cross-dissolve ${span.transitionOut.toFixed(1)}s`}
                  >
                    <Blend className="size-2.5" />
                  </div>
                ) : null
              )}
          </div>

          {belowTracks.map((track) => (
            <div
              key={`ov-${track}`}
              className="relative mt-1.5"
              style={{ height: OVERLAY_H }}
              data-drop={placementAttr({ kind: "track", track })}
              onPointerDown={deselectIfSelf}
              {...overlayDropHandlers({ kind: "track", track })}
            >
              {insertMode && insertZone(track - 1, "bottom")}
              {overlayClips
                .filter((c) => c.track === track)
                .map((c) => (
                  <OverlayClipView
                    key={c.id}
                    clip={c}
                    asset={assets.find((x) => x.id === c.assetId)}
                    pps={pps}
                    selected={selKeys.has(`overlayClip:${c.id}`)}
                    resolveTarget={resolveDropTrack}
                    onCrossMove={previewCross}
                    onCrossDrop={onOverlayCrossDrop}
                    onDragActive={setVideoDragging}
                  />
                ))}
              {samePlacement(overlayDrop?.target ?? null, { kind: "track", track }) && (
                <div
                  className="pointer-events-none absolute top-0.5 rounded-lg border-[1.5px] border-dashed border-[#0a84ff]/70 bg-[#0a84ff]/10"
                  style={{
                    left: overlayDrop!.t * pps,
                    width: Math.max(10, overlayDrop!.len * pps - CLIP_GAP),
                    height: OVERLAY_H - 4,
                  }}
                />
              )}
            </div>
          ))}

          {audioClips.length > 0 && (
            <div className="relative mt-1.5" style={{ height: AUDIO_H }} onPointerDown={deselectIfSelf}>
              {audioClips.map((a) => (
                <AudioView
                  key={a.id}
                  clip={a}
                  asset={assets.find((x) => x.id === a.assetId)}
                  pps={pps}
                  selected={selKeys.has(`audio:${a.id}`)}
                />
              ))}
            </div>
          )}

          {overlays.length > 0 && (
            <div
              className="relative mt-1.5"
              style={{
                height:
                  Math.max(overlayLanes.count, (textDrag?.targetRow ?? -1) + 1) * TEXT_H,
              }}
              onPointerDown={deselectIfSelf}
            >
              {overlays.map((o) => {
                const baseRow = overlayLanes.rowOf.get(o.lane ?? 0) ?? 0;
                const row = textDrag?.id === o.id ? textDrag.targetRow : baseRow;
                return (
                  <TextBar
                    key={o.id}
                    overlay={o}
                    pps={pps}
                    top={row * TEXT_H}
                    baseRow={baseRow}
                    laneCount={overlayLanes.count}
                    selected={selKeys.has(`text:${o.id}`)}
                    onLaneDrag={onTextLaneDrag}
                    onLaneDrop={onTextLaneDrop}
                  />
                );
              })}
            </div>
          )}

          {subtitles.showOnTimeline && subtitles.cues.length > 0 && (
            <div
              className="tl-sub-track relative mt-1.5"
              style={{ height: SUB_H }}
              onPointerDown={deselectIfSelf}
            >
              {subtitles.cues.map((c) => (
                <SubBar
                  key={c.id}
                  cue={c}
                  pps={pps}
                  selected={selKeys.has(`cue:${c.id}`)}
                />
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
      className="tl-hover-line pointer-events-none absolute top-0 bottom-2 z-30 w-px bg-foreground/30"
      style={{ transform: `translateX(${skimTime * pps}px)` }}
    />
  );
}

/**
 * Saves the current multi-selection as a by-reference library template — the
 * source media plus the edit that arranges it, never a flattened video. Re-adding
 * it from the library re-materializes editable clips, overlays, and captions.
 */
function SaveSelectionButton() {
  const multiSelection = useEditor((s) => s.multiSelection);
  const [state, setState] = useState<"idle" | "saving" | "done">("idle");
  if (multiSelection.length === 0) return null;

  const save = async () => {
    const s = useEditor.getState();
    const input = s.selectionTemplate();
    if (!s.projectId || !input) return;
    setState("saving");
    try {
      await saveTemplate(s.projectId, input);
      setState("done");
      setTimeout(() => setState("idle"), 1800);
    } catch {
      setState("idle");
    }
  };

  return (
    <Button
      variant="ghost"
      size="sm"
      title="Save the selection as a reusable template (kept by reference)"
      disabled={state === "saving"}
      onClick={save}
    >
      {state === "saving" ? (
        <Loader2 className="animate-spin" />
      ) : state === "done" ? (
        <Check />
      ) : (
        <FolderPlus />
      )}
      {state === "done" ? "Saved" : "Save template"}
    </Button>
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
    <div className="relative h-[26px] cursor-ew-resize" onPointerDown={onScrub}>
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
      {/* The ruler baseline bleeds past the content's side padding so it runs
          flush to both window edges, matching the full-width toolbar divider. */}
      <div
        className="pointer-events-none absolute bottom-0 h-px bg-border"
        style={{ left: -PAD_SIDE, right: -PAD_SIDE }}
      />
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
      className="pointer-events-none absolute top-0 bottom-2 left-0 z-30 w-[1.5px] bg-[#0a84ff] shadow-[0_0_8px_rgba(10,132,255,0.6)]"
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
  insertAtIndex,
  insertLen,
  scrollRef,
  onDrag,
  onDrop,
  resolveTarget,
  onCrossMove,
  onCrossDrop,
  onDragActive,
}: {
  span: ClipSpan;
  index: number;
  pps: number;
  selected: boolean;
  drag: ClipDrag | null;
  /** While a media asset is dragged in, clips at/after this index part to
   * open a slot of `insertLen` seconds. Null when no asset drag is active. */
  insertAtIndex: number | null;
  insertLen: number;
  scrollRef: React.RefObject<HTMLDivElement | null>;
  onDrag: (id: string, dx: number, dy: number) => void;
  onDrop: (id: string, dx: number | null) => void;
  /** Which drop the given screen point is over (track / base / insert gap). */
  resolveTarget: (clientX: number, clientY: number) => TrackTarget;
  /** Preview a cross-track drop (null clears it). */
  onCrossMove: (target: TrackTarget | null, start?: number, len?: number) => void;
  /** Commit a cross-track drop of this clip at `start`. */
  onCrossDrop: (id: string, target: TrackTarget, start: number) => void;
  /** Toggle the between-track insertion zones while this clip is dragging. */
  onDragActive: (active: boolean) => void;
}) {
  // Left-trim keeps the box and its frames pinned: the handle sweeps through
  // the clip and the leading area dims as "hidden"; release collapses it.
  const [trim, setTrim] = useState<{ side: "l"; in0: number } | { side: "r" } | null>(null);
  const { clip, asset } = span;
  const speed = clipSpeed(clip);
  const w = span.len * pps;
  const left = span.start * pps;
  const trimL = trim?.side === "l" ? trim : null;
  const stripIn = trimL ? Math.min(clip.in, trimL.in0) : clip.in;
  // Source seconds → timeline px goes through the clip's speed.
  const hidPx = trimL ? Math.max(0, ((clip.in - trimL.in0) / speed) * pps) : 0;
  const boxW = trimL ? ((clip.out - stripIn) / speed) * pps : w;
  const isDragged = drag?.id === clip.id;
  // Neighbors part to make room for the open slot.
  const reorderShift =
    !drag || isDragged
      ? 0
      : drag.from < index && index <= drag.to
        ? -drag.len
        : drag.to <= index && index < drag.from
          ? drag.len
          : 0;
  // Clips at/after the media-drop point slide right to open the insertion slot.
  const insertShift = insertAtIndex !== null && index >= insertAtIndex ? insertLen : 0;
  const shiftSec = reorderShift + insertShift;
  const parting = drag !== null || insertAtIndex !== null;

  // During a left-trim the strip is computed from the drag-start in-point so
  // every frame stays pinned in place while the hidden region sweeps over it.
  const filmstrip = useMemo(() => {
    if (!asset.thumbs?.length || !asset.thumbStep) return [];
    const aspect = (asset.width ?? 16) / Math.max(1, asset.height ?? 9);
    const imgW = Math.max(26, Math.round((VIDEO_H - 4) * aspect));
    const count = Math.min(120, Math.ceil(boxW / imgW));
    return Array.from({ length: count }, (_, k) => {
      const timeAt = stripIn + ((k * imgW + imgW / 2) / pps) * speed;
      const idx = Math.min(
        asset.thumbs!.length - 1,
        Math.max(0, Math.floor(timeAt / asset.thumbStep!))
      );
      return { src: asset.thumbs![idx], left: k * imgW, width: imgW };
    });
  }, [asset, stripIn, boxW, pps, speed]);

  const onBody = (e: React.PointerEvent) => {
    if (e.metaKey || e.shiftKey) {
      useEditor.getState().toggleSelect({ kind: "clip", id: clip.id });
      return;
    }
    const s = useEditor.getState();
    s.select({ kind: "clip", id: clip.id });
    // Clicking anywhere on the timeline moves the playhead — clips included.
    const rect = e.currentTarget.getBoundingClientRect();
    s.seek(span.start + (e.clientX - rect.left) / pps);
    const el = scrollRef.current;
    const sc0 = el?.scrollLeft ?? 0;
    let effDx = 0;
    let live = false;
    let target: TrackTarget = { kind: "base" };
    let dropStart = span.start;
    startDrag(e, {
      onMove: (dx, dy, ev) => {
        if (!live && Math.abs(dx) < 4 && Math.abs(dy) < 4) return;
        if (!live) onDragActive(true);
        live = true;
        if (el) {
          const r = el.getBoundingClientRect();
          if (ev.clientX > r.right - 36) el.scrollLeft += 14;
          else if (ev.clientX < r.left + 36) el.scrollLeft -= 14;
        }
        effDx = dx + ((el?.scrollLeft ?? sc0) - sc0);
        dropStart = Math.max(0, span.start + effDx / pps);
        // On the base row it's a reorder; over an upper track or a gap it lifts.
        target = resolveTarget(ev.clientX, ev.clientY);
        if (target.kind === "base") {
          onCrossMove(null);
          onDrag(clip.id, effDx, Math.max(-26, Math.min(14, dy)));
        } else {
          onCrossMove(target, dropStart, span.len);
        }
      },
      onUp: () => {
        onDragActive(false);
        if (!live) return onDrop(clip.id, null);
        if (target.kind === "base") onDrop(clip.id, effDx);
        else onCrossDrop(clip.id, target, dropStart);
      },
    });
  };

  // Shift later titles/captions by however much this clip's footprint changed.
  const rippleTrim = (len0: number) => {
    const c = useEditor.getState().clips.find((x) => x.id === clip.id);
    if (c) useEditor.getState().rippleShift(span.start + len0, clipLen(c) - len0);
  };

  const onTrimLeft = (e: React.PointerEvent) => {
    const s = useEditor.getState();
    s.select({ kind: "clip", id: clip.id });
    s.pushHistory();
    const in0 = clip.in;
    const len0 = span.len;
    setTrim({ side: "l", in0 });
    startDrag(e, {
      onMove: (dx) => {
        const nin = Math.min(clip.out - 0.15, Math.max(0, in0 + (dx / pps) * speed));
        s.updateClipTransient(clip.id, { in: nin });
      },
      onUp: () => {
        setTrim(null);
        rippleTrim(len0);
      },
    });
  };

  const onTrimRight = (e: React.PointerEvent) => {
    const s = useEditor.getState();
    s.select({ kind: "clip", id: clip.id });
    s.pushHistory();
    setTrim({ side: "r" });
    const out0 = clip.out;
    const len0 = span.len;
    startDrag(e, {
      onMove: (dx) => {
        const nout = Math.max(clip.in + 0.15, Math.min(asset.duration, out0 + (dx / pps) * speed));
        s.updateClipTransient(clip.id, { out: nout });
      },
      onUp: () => {
        setTrim(null);
        rippleTrim(len0);
      },
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
            : parting && "transition-transform duration-150 ease-out"
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
        {selected && (
          // A blue wash over the whole clip so a multi-selection reads at a
          // glance, not just from the thin border.
          <div className="pointer-events-none absolute inset-0 z-[1] bg-[#0a84ff]/25" />
        )}
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
        {(clip.speed ?? 1) !== 1 && (
          <span
            className="tl-speed-chip absolute right-1.5 bottom-1 z-2 rounded-[5px] bg-black/70 px-1 py-px font-mono text-[9.5px] tabular-nums text-white"
            title={`${clip.speed}× speed`}
          >
            {+(clip.speed ?? 1).toFixed(2)}×
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
    if (e.metaKey || e.shiftKey) {
      useEditor.getState().toggleSelect({ kind: "audio", id: clip.id });
      return;
    }
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

/** Timeline footprint (seconds) of an overlay clip, honoring its speed. */
function overlayLen(c: OverlayClip) {
  const src = c.out - c.in;
  const eff = c.speed && c.speed > 0 ? src / c.speed : src;
  return Math.max(0.1, eff);
}

/**
 * An upper-track video clip: free-positioned by `start` like an audio clip,
 * draggable and trimmable. Full-frame layers (`scale === 1`) read as a stacked
 * composite; smaller ones are picture-in-picture. Hidden clips gray out.
 */
function OverlayClipView({
  clip,
  asset,
  pps,
  selected,
  resolveTarget,
  onCrossMove,
  onCrossDrop,
  onDragActive,
}: {
  clip: OverlayClip;
  asset: MediaAsset | undefined;
  pps: number;
  selected: boolean;
  resolveTarget: (clientX: number, clientY: number) => TrackTarget;
  onCrossMove: (target: TrackTarget | null, start?: number, len?: number) => void;
  onCrossDrop: (id: string, target: TrackTarget, start: number) => void;
  onDragActive: (active: boolean) => void;
}) {
  const w = Math.max(10, overlayLen(clip) * pps);

  // Same filmstrip as a base clip so an overlay reads as a video, not a
  // featureless bar — sampled across the clip's trimmed span.
  const filmstrip = useMemo(() => {
    if (!asset?.thumbs?.length || !asset.thumbStep) return [];
    const aspect = (asset.width ?? 16) / Math.max(1, asset.height ?? 9);
    const imgW = Math.max(24, Math.round((OVERLAY_H - 4) * aspect));
    const count = Math.min(120, Math.ceil(w / imgW));
    const speed = clip.speed && clip.speed > 0 ? clip.speed : 1;
    return Array.from({ length: count }, (_, k) => {
      const at = clip.in + ((k * imgW + imgW / 2) / pps) * speed;
      const idx = Math.min(
        asset.thumbs!.length - 1,
        Math.max(0, Math.floor(at / asset.thumbStep!))
      );
      return { src: asset.thumbs![idx], left: k * imgW, width: imgW };
    });
  }, [asset, clip.in, clip.speed, w, pps]);

  if (!asset) return null;

  const onBody = (e: React.PointerEvent) => {
    if (e.metaKey || e.shiftKey) {
      useEditor.getState().toggleSelect({ kind: "overlayClip", id: clip.id });
      return;
    }
    const s = useEditor.getState();
    s.select({ kind: "overlayClip", id: clip.id });
    s.seek(clip.start + (e.clientX - e.currentTarget.getBoundingClientRect().left) / pps);
    const start0 = clip.start;
    let live = false;
    let target: TrackTarget = { kind: "track", track: clip.track };
    let dropStart = clip.start;
    startDrag(e, {
      onMove: (dx, dy, ev) => {
        if (!live && Math.abs(dx) < 4 && Math.abs(dy) < 4) return;
        if (!live) {
          s.pushHistory();
          onDragActive(true);
        }
        live = true;
        dropStart = Math.max(0, start0 + dx / pps);
        s.updateOverlayClipTransient(clip.id, { start: dropStart });
        target = resolveTarget(ev.clientX, ev.clientY);
        // Staying on its own track is a plain slide; anything else previews a move.
        if (samePlacement(target, { kind: "track", track: clip.track })) onCrossMove(null);
        else onCrossMove(target, dropStart, overlayLen(clip));
      },
      onUp: () => {
        onDragActive(false);
        onCrossMove(null);
        if (live) onCrossDrop(clip.id, target, dropStart);
      },
    });
  };

  const onTrimLeft = (e: React.PointerEvent) => {
    const s = useEditor.getState();
    s.select({ kind: "overlayClip", id: clip.id });
    s.pushHistory();
    const in0 = clip.in;
    const start0 = clip.start;
    startDrag(e, {
      onMove: (dx) => {
        let d = dx / pps;
        d = Math.max(d, -in0, -start0);
        d = Math.min(d, clip.out - 0.15 - in0);
        s.updateOverlayClipTransient(clip.id, { in: in0 + d, start: start0 + d });
      },
    });
  };

  const onTrimRight = (e: React.PointerEvent) => {
    const s = useEditor.getState();
    s.select({ kind: "overlayClip", id: clip.id });
    s.pushHistory();
    const out0 = clip.out;
    startDrag(e, {
      onMove: (dx) => {
        const nout = Math.max(clip.in + 0.15, Math.min(asset.duration, out0 + dx / pps));
        s.updateOverlayClipTransient(clip.id, { out: nout });
      },
    });
  };

  return (
    <div
      className={cn(
        "tl-overlay-clip group absolute top-0.5 cursor-grab overflow-hidden rounded-lg bg-neutral-200 shadow-[inset_0_0_0_1px_rgba(0,0,0,0.12)]",
        selected && SELECTED_SHADOW,
        clip.hidden && "opacity-40 grayscale"
      )}
      style={{ left: clip.start * pps, width: Math.max(10, w - CLIP_GAP), height: OVERLAY_H - 4 }}
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
      {selected && (
        <div className="pointer-events-none absolute inset-0 z-[1] bg-[#0a84ff]/25" />
      )}
      {clip.muted && (
        <span className="tl-mute-chip absolute bottom-1 left-1 z-2 grid size-[18px] place-items-center rounded-[5px] bg-black/70 text-white" title="Muted">
          <VolumeX className="size-3" />
        </span>
      )}
      {(clip.speed ?? 1) !== 1 && (
        <span
          className="tl-speed-chip absolute right-1.5 bottom-1 z-2 rounded-[5px] bg-black/70 px-1 py-px font-mono text-[9.5px] tabular-nums text-white"
          title={`${clip.speed}× speed`}
        >
          {+(clip.speed ?? 1).toFixed(2)}×
        </span>
      )}
      <span className={cn(trimHandle, "tl-trim-l left-0")} onPointerDown={onTrimLeft} />
      <span className={cn(trimHandle, "tl-trim-r right-0")} onPointerDown={onTrimRight} />
    </div>
  );
}

function TextBar({
  overlay: o,
  pps,
  top,
  baseRow,
  laneCount,
  selected,
  onLaneDrag,
  onLaneDrop,
}: {
  overlay: TextOverlay;
  pps: number;
  top: number;
  baseRow: number;
  laneCount: number;
  selected: boolean;
  onLaneDrag: (id: string, targetRow: number) => void;
  onLaneDrop: (id: string, targetRow: number) => void;
}) {
  const w = Math.max(8, (o.end - o.start) * pps);

  const onBody = (e: React.PointerEvent) => {
    if (e.metaKey || e.shiftKey) {
      useEditor.getState().toggleSelect({ kind: "text", id: o.id });
      return;
    }
    const s = useEditor.getState();
    s.select({ kind: "text", id: o.id });
    s.pushHistory();
    const start0 = o.start;
    const len = o.end - o.start;
    let targetRow = baseRow;
    startDrag(e, {
      onMove: (dx, dy) => {
        const start = Math.max(0, start0 + dx / pps);
        s.updateOverlayTransient(o.id, { start, end: start + len });
        // Vertical drag retracks the title; one row past the end opens a new one.
        const next = Math.min(laneCount, Math.max(0, baseRow + Math.round(dy / TEXT_H)));
        if (next !== targetRow) {
          targetRow = next;
          onLaneDrag(o.id, targetRow);
        }
      },
      onUp: () => onLaneDrop(o.id, targetRow),
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
        "tl-text-bar group absolute flex cursor-grab items-center overflow-hidden rounded-md bg-gradient-to-b from-purple-500 to-purple-600 shadow-[inset_0_0_0_1px_rgba(0,0,0,0.1)]",
        selected && SELECTED_SHADOW
      )}
      style={{ left: o.start * pps, top: top + 2, width: w, height: TEXT_H - 6 }}
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

/** A subtitle cue on its track: click selects (⌫ deletes it), drag to retime,
 * edges to trim. Editing the words happens in the Subtitles panel. */
function SubBar({ cue, pps, selected }: { cue: SubtitleCue; pps: number; selected: boolean }) {
  const w = Math.max(8, (cue.end - cue.start) * pps);

  const finish = (moved: boolean) => {
    const s = useEditor.getState();
    if (moved) s.sortCues();
    else s.seek(cue.start + 0.001);
  };

  const onBody = (e: React.PointerEvent) => {
    if (e.metaKey || e.shiftKey) {
      useEditor.getState().toggleSelect({ kind: "cue", id: cue.id });
      return;
    }
    const s = useEditor.getState();
    s.select({ kind: "cue", id: cue.id });
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
    s.select({ kind: "cue", id: cue.id });
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
      className={cn(
        "tl-sub-bar group absolute top-px flex cursor-grab items-center overflow-hidden rounded-[5px] bg-gradient-to-b from-amber-300 to-amber-400 shadow-[inset_0_0_0_1px_rgba(0,0,0,0.12)]",
        selected && SELECTED_SHADOW
      )}
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
