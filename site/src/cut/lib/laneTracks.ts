"use client";

/**
 * The lane-track coordinator: the one place for how items on the timeline's
 * free-positioned tracks behave. Audio, titles, upper video layers, and
 * subtitle cues all route their pointer gestures through here, so selection,
 * moving, resizing, collision, and snapping work identically everywhere — and
 * a new track type gets every behavior by writing one small adapter.
 *
 * The shared behaviors:
 * - Grab: cmd/shift toggles the multi-selection; a plain grab selects the
 *   item and moves the playhead under the pointer.
 * - Move: the bar ghosts under the pointer while same-lane neighbors part
 *   around the landing slot; either edge snaps to logical times; on
 *   multi-lane kinds a vertical drag retracks the item, one row past the end
 *   opens a new track, and lanes stay contiguous so empty ones collapse.
 * - Resize: edges snap; growing into a neighbor pushes its whole run along;
 *   the left edge rubber-bands past its floor (the timeline start, packed
 *   leaders, or a media item's first sample) and springs back on release.
 * - Placement collision: adding/pasting slides to the next free slot on the
 *   lane — the store's `nextFreeStart` is that one primitive.
 * - Cut: the store's `splitAtPlayhead` slices whichever kind is selected.
 *
 * The base video track and the upper video tracks keep their richer
 * verticality (lifting between tracks, insert zones, the base row) by passing
 * a `vertical` strategy to the move gesture; everything else about them is
 * the shared behavior.
 */

import type React from "react";
import { refFromAsset, startPointerRefDrag } from "./assetRef";
import { startDrag } from "./drag";
import { clipLen, getClipSpans, projectDuration, useEditor } from "./store";
import type {
  AudioClip,
  MediaAsset,
  OverlayClip,
  Selection,
  SubtitleCue,
  TextOverlay,
  VideoClip,
} from "./types";

type S = ReturnType<typeof useEditor.getState>;

export type LaneKind = "clip" | "audio" | "text" | "overlayClip" | "cue";

/** Visual gutter between adjacent clips (iMovie); time math stays exact. */
export const CLIP_GAP = 4;
/** Pull a dragged or resized edge to a logical time within this many px. */
export const SNAP_PX = 6;
/** How far (px) a left edge can rubber-band past its floor before springing back. */
const LEFT_RUBBER_PX = 32;

/** Normalized geometry of one item on a lane track. */
interface LaneItem {
  id: string;
  start: number;
  len: number;
  lane: number;
}

type Patch<T> = { id: string; patch: Partial<T> };

/**
 * Everything kind-specific, so the gestures stay generic. Patches are built
 * from gesture-start snapshots, which makes a retreating drag restore the
 * originals exactly (including a cue's word timings).
 */
interface LaneAdapter<T> {
  minLen: number;
  /** Vertical drag retracks among this kind's own lanes. */
  multiLane: boolean;
  raws(s: S): T[];
  view(raw: T): LaneItem;
  /** Apply patches transiently (no undo entry; the gesture checkpoints once). */
  apply(patches: Patch<T>[]): void;
  movePatch(raw: T, start: number): Patch<T>;
  trimLeftPatch(raw: T, newStart: number): Patch<T>;
  trimRightPatch(raw: T, newEnd: number): Patch<T>;
  /** Earliest timeline start the left edge can reveal to (media source floor). */
  leftFloor(raw: T): number;
  /** Longest timeline footprint the item can grow to (media source bound). */
  maxLen(s: S, raw: T): number;
  /** Write a committed lane number (multi-lane kinds only). */
  lanePatch?(raw: T, lane: number): Patch<T>;
  /** The media behind the item, so dragging it can feed reference drop zones. */
  assetOf?(s: S, raw: T): MediaAsset | undefined;
  /** After a committed move (e.g. keep cues sorted). */
  onMoved?(): void;
}

const speedOf = (c: { speed?: number }) => (c.speed && c.speed > 0 ? c.speed : 1);

const clipAdapter: LaneAdapter<VideoClip> = {
  minLen: 0.15,
  // Verticality is the video placement system (upper tracks and insert
  // zones), fed in as the move gesture's `vertical` strategy.
  multiLane: false,
  raws: (s) => s.clips,
  view: (c) => ({ id: c.id, start: c.start, len: clipLen(c), lane: 0 }),
  apply: (patches) => useEditor.getState().updateClipsTransient(patches),
  movePatch: (c, start) => ({ id: c.id, patch: { start } }),
  trimLeftPatch: (c, newStart) => ({
    id: c.id,
    patch: { start: newStart, in: c.in + (newStart - c.start) * speedOf(c) },
  }),
  trimRightPatch: (c, newEnd) => ({
    id: c.id,
    patch: { out: c.in + (newEnd - c.start) * speedOf(c) },
  }),
  leftFloor: (c) => Math.max(0, c.start - c.in / speedOf(c)),
  maxLen: (s, c) => {
    const a = s.assets.find((x) => x.id === c.assetId);
    // A still has no source length, so its clip can stretch to any duration.
    if (a?.type === "image") return Infinity;
    return ((a?.duration ?? c.out) - c.in) / speedOf(c);
  },
  assetOf: (s, c) => s.assets.find((x) => x.id === c.assetId),
  onMoved: () => useEditor.getState().sortClips(),
};

const audioAdapter: LaneAdapter<AudioClip> = {
  minLen: 0.15,
  multiLane: true,
  raws: (s) => s.audioClips,
  view: (a) => ({ id: a.id, start: a.start, len: clipLen(a), lane: a.lane ?? 0 }),
  apply: (patches) => useEditor.getState().updateAudiosTransient(patches),
  movePatch: (a, start) => ({ id: a.id, patch: { start } }),
  trimLeftPatch: (a, newStart) => ({
    id: a.id,
    patch: { start: newStart, in: a.in + (newStart - a.start) * speedOf(a) },
  }),
  trimRightPatch: (a, newEnd) => ({
    id: a.id,
    patch: { out: a.in + (newEnd - a.start) * speedOf(a) },
  }),
  leftFloor: (a) => Math.max(0, a.start - a.in / speedOf(a)),
  maxLen: (s, a) =>
    ((s.assets.find((x) => x.id === a.assetId)?.duration ?? a.out) - a.in) / speedOf(a),
  lanePatch: (a, lane) => ({ id: a.id, patch: { lane: lane > 0 ? lane : undefined } }),
  assetOf: (s, a) => s.assets.find((x) => x.id === a.assetId),
};

const textAdapter: LaneAdapter<TextOverlay> = {
  minLen: 0.2,
  multiLane: true,
  raws: (s) => s.overlays,
  view: (o) => ({ id: o.id, start: o.start, len: o.end - o.start, lane: o.lane ?? 0 }),
  apply: (patches) => useEditor.getState().updateOverlaysTransient(patches),
  movePatch: (o, start) => ({ id: o.id, patch: { start, end: start + (o.end - o.start) } }),
  trimLeftPatch: (o, newStart) => ({ id: o.id, patch: { start: newStart } }),
  trimRightPatch: (o, newEnd) => ({ id: o.id, patch: { end: newEnd } }),
  leftFloor: () => 0,
  maxLen: () => Infinity,
  lanePatch: (o, lane) => ({ id: o.id, patch: { lane } }),
};

const overlayClipAdapter: LaneAdapter<OverlayClip> = {
  minLen: 0.15,
  // Verticality is the video placement system (tracks and insert zones), fed
  // in as the move gesture's `vertical` strategy.
  multiLane: false,
  raws: (s) => s.overlayClips,
  view: (c) => ({ id: c.id, start: c.start, len: clipLen(c), lane: c.track }),
  apply: (patches) => useEditor.getState().updateOverlayClipsTransient(patches),
  movePatch: (c, start) => ({ id: c.id, patch: { start } }),
  trimLeftPatch: (c, newStart) => ({
    id: c.id,
    patch: { start: newStart, in: c.in + (newStart - c.start) * speedOf(c) },
  }),
  trimRightPatch: (c, newEnd) => ({
    id: c.id,
    patch: { out: c.in + (newEnd - c.start) * speedOf(c) },
  }),
  leftFloor: (c) => Math.max(0, c.start - c.in / speedOf(c)),
  maxLen: (s, c) =>
    ((s.assets.find((x) => x.id === c.assetId)?.duration ?? c.out) - c.in) / speedOf(c),
  assetOf: (s, c) => s.assets.find((x) => x.id === c.assetId),
};

const cueAdapter: LaneAdapter<SubtitleCue> = {
  minLen: 0.15,
  multiLane: false,
  raws: (s) => s.subtitles.cues,
  view: (c) => ({ id: c.id, start: c.start, len: c.end - c.start, lane: 0 }),
  apply: (patches) => useEditor.getState().updateCuesTransient(patches),
  // Retiming detaches a cue from its word timings; an unmoved patch restores
  // the originals, so parted neighbors that flow back keep theirs.
  movePatch: (c, start) => ({
    id: c.id,
    patch: {
      start,
      end: start + (c.end - c.start),
      words: Math.abs(start - c.start) < 1e-6 ? c.words : undefined,
    },
  }),
  trimLeftPatch: (c, newStart) => ({ id: c.id, patch: { start: newStart, words: undefined } }),
  trimRightPatch: (c, newEnd) => ({ id: c.id, patch: { end: newEnd, words: undefined } }),
  leftFloor: () => 0,
  maxLen: () => Infinity,
  onMoved: () => useEditor.getState().sortCues(),
};

type LaneRaw = VideoClip | AudioClip | TextOverlay | OverlayClip | SubtitleCue;
// The generic parameter is erased at the registry boundary; each gesture only
// feeds an adapter values that came out of that same adapter, so this is safe.
const ADAPTERS: Record<LaneKind, LaneAdapter<LaneRaw>> = {
  clip: clipAdapter as unknown as LaneAdapter<LaneRaw>,
  audio: audioAdapter as unknown as LaneAdapter<LaneRaw>,
  text: textAdapter as unknown as LaneAdapter<LaneRaw>,
  overlayClip: overlayClipAdapter as unknown as LaneAdapter<LaneRaw>,
  cue: cueAdapter as unknown as LaneAdapter<LaneRaw>,
};

/** Logical times an edge can snap to: the timeline start, the base track's
 * cut points and end, the playhead, and every other lane item's edges across
 * all track kinds — a title can align to a music hit and vice versa. */
function snapTargets(s: S, kind: LaneKind, selfId: string): number[] {
  const pts = new Set<number>([0]);
  for (const sp of getClipSpans(s.clips, s.assets)) {
    // The visible joint: a dissolved pair meets at the overlap midpoint (where
    // the clip boxes are inset to), a hard cut at the footprint end.
    pts.add(sp.start + sp.len - sp.transitionOut / 2);
  }
  pts.add(projectDuration(s));
  pts.add(s.currentTime);
  for (const k of Object.keys(ADAPTERS) as LaneKind[]) {
    for (const raw of ADAPTERS[k].raws(s)) {
      const v = ADAPTERS[k].view(raw);
      if (k === kind && v.id === selfId) continue;
      pts.add(v.start);
      pts.add(v.start + v.len);
    }
  }
  return [...pts];
}

/** The nearest snap target within `tol` seconds, or null. */
function nearestSnap(t: number, targets: number[], tol: number): number | null {
  let best: number | null = null;
  let bd = tol;
  for (const T of targets) {
    const d = Math.abs(t - T);
    if (d <= bd) {
      bd = d;
      best = T;
    }
  }
  return best;
}

/** Ease that overshoots the target then settles — the elastic snap-back feel. */
function easeOutBack(p: number): number {
  const c1 = 1.70158;
  const c3 = c1 + 1;
  return 1 + c3 * Math.pow(p - 1, 3) + c1 * Math.pow(p - 1, 2);
}

/** Damp an overshoot in px so it gives but resists, saturating near `max`. */
function rubberBand(overPx: number, max: number): number {
  return max * (1 - Math.exp(-Math.max(0, overPx) / max));
}

// A snapped edge draws its guide where the bar is actually rendered: a left
// edge at the time itself, a right edge inset by the CLIP_GAP gutter, so the
// line hugs the bar's visible right edge instead of the next item's start.
const leftGuide = (t: number, pps: number) => t * pps;
const rightGuide = (t: number, pps: number) => t * pps - CLIP_GAP;

// The in-flight elastic snap-back; any new gesture cancels it.
let snapBackRaf = 0;

/** The live move drag, published so the Timeline can render the ghost, the
 * landing slot, and grow the lane stack while a new row is hovered. */
export interface LaneDrag {
  kind: LaneKind;
  id: string;
  targetRow: number; // hovered display row (one past the end = new track)
  ghostX: number; // ghost left in px — follows the pointer
  slotStart: number; // resolved landing start, seconds
  len: number; // dragged item length, seconds
  /** Carried off its own lane set (an upper video layer headed elsewhere);
   * the home slot preview hides while away. */
  away?: boolean;
}

export interface LaneMoveUI<V = unknown> {
  pps: number;
  rowH: number;
  /** Display rows currently in use; targetRow may go one past to open a new track. */
  laneCount: number;
  /** The grabbed item's current display row. */
  baseRow: number;
  /** Publish (or clear) the in-flight drag so the slot and rows track it. */
  onDrag(d: LaneDrag | null): void;
  /** Paint (or clear) the snap guide at this stage-x pixel. */
  onSnap(x: number | null): void;
  /** Cross-structure verticality (upper video tracks): resolve where the
   * pointer is, preview non-home targets, and commit the drop. When absent,
   * vertical motion retracks among this kind's own lanes. */
  vertical?: {
    resolve(ev: PointerEvent): V;
    isHome(target: V): boolean;
    preview(target: V | null, start: number, len: number): void;
    commit(id: string, target: V, start: number): void;
    setActive?(active: boolean): void;
  };
}

/** Grab an item: select (or cmd/shift-toggle) it, then drag to move it along
 * and across lanes with parting, snapping, and lane retracking. */
export function startLaneMove<V = unknown>(
  e: React.PointerEvent,
  kind: LaneKind,
  id: string,
  ui: LaneMoveUI<V>
) {
  cancelAnimationFrame(snapBackRaf);
  const s = useEditor.getState();
  if (e.metaKey || e.shiftKey) {
    s.toggleSelect({ kind, id } as NonNullable<Selection>);
    return;
  }
  const ad = ADAPTERS[kind];
  const raw0 = ad.raws(s).find((r) => ad.view(r).id === id);
  if (!raw0) return;
  const self = ad.view(raw0);
  s.select({ kind, id } as Selection);
  // Clicking anywhere on the timeline moves the playhead — bars included.
  s.seek(self.start + (e.clientX - e.currentTarget.getBoundingClientRect().left) / ui.pps);
  s.pushHistory();

  const start0 = self.start;
  const len = self.len;
  // Everyone else's resting spot, captured once: each move re-lays the lane
  // from these, so a retreating drag lets parted neighbors flow back.
  const rest = ad
    .raws(s)
    .filter((r) => ad.view(r).id !== id)
    .map((r) => ({ raw: r, view: ad.view(r) }));
  const usedLanes = [...new Set([...rest.map((x) => x.view.lane), self.lane])].sort(
    (a, b) => a - b
  );
  const targets = snapTargets(s, kind, id);
  const tol = SNAP_PX / ui.pps;
  // Dragging a media-backed item can also hand its asset to a reference drop
  // zone (AI chat, the image/video creators).
  const asset = ad.assetOf?.(s, raw0);
  const refDrag = asset ? startPointerRefDrag(refFromAsset(asset)) : null;

  let live = false;
  let targetRow = ui.baseRow;
  let slotStart = start0;
  let ds = start0;
  let awayTarget: V | null = null;

  const restRestore = () => ad.apply(rest.map((x) => ad.movePatch(x.raw, x.view.start)));

  startDrag(e, {
    onMove: (dx, dy, ev) => {
      if (!live && Math.abs(dx) < 4 && Math.abs(dy) < 4) return;
      if (!live) ui.vertical?.setActive?.(true);
      live = true;
      refDrag?.move(ev);
      ds = Math.max(0, start0 + dx / ui.pps);

      // Carried off its own lane set (an upper video layer headed to another
      // track, the base row, or an insert gap): neighbors flow back and the
      // placement system previews the target instead.
      if (ui.vertical) {
        const target = ui.vertical.resolve(ev);
        if (!ui.vertical.isHome(target)) {
          awayTarget = target;
          restRestore();
          ui.onSnap(null);
          ui.vertical.preview(target, ds, len);
          ui.onDrag({
            kind,
            id,
            targetRow: ui.baseRow,
            ghostX: ds * ui.pps,
            slotStart: ds,
            len,
            away: true,
          });
          return;
        }
        awayTarget = null;
        ui.vertical.preview(null, 0, 0);
      }

      // Vertical drag retracks the item; one row past the end opens a new one.
      targetRow = ad.multiLane
        ? Math.min(ui.laneCount, Math.max(0, ui.baseRow + Math.round(dy / ui.rowH)))
        : ui.baseRow;
      // A brand-new row has no neighbors to part.
      const lane = targetRow < usedLanes.length ? usedLanes[targetRow] : Infinity;

      // Snap whichever edge of the moving item lands nearest a logical time.
      let start = ds;
      let guide: number | null = null;
      if (!ev.metaKey) {
        const end = start + len;
        let best = { d: tol, start, px: null as number | null };
        for (const T of targets) {
          if (Math.abs(start - T) < best.d)
            best = { d: Math.abs(start - T), start: T, px: leftGuide(T, ui.pps) };
          if (Math.abs(end - T) < best.d)
            best = { d: Math.abs(end - T), start: T - len, px: rightGuide(T, ui.pps) };
        }
        if (best.px !== null) {
          start = Math.max(0, best.start);
          guide = best.px;
        }
      }
      // Same-lane neighbors part around the slot: ones whose midpoint sits
      // left of the ghost's center keep their spot (the slot lands after
      // them), the rest slide right as a run to make room.
      const others = rest
        .filter((x) => x.view.lane === lane)
        .sort((a, b) => a.view.start - b.view.start);
      const center = ds + len / 2;
      const before = others.filter((x) => x.view.start + x.view.len / 2 <= center);
      const after = others.filter((x) => x.view.start + x.view.len / 2 > center);
      const clamped = Math.max(start, ...before.map((b) => b.view.start + b.view.len));
      if (clamped !== start) guide = null;
      slotStart = clamped;
      const delta = after.length ? Math.max(0, clamped + len - after[0].view.start) : 0;
      const pushed = new Set(after.map((x) => x.view.id));
      ui.onSnap(guide);
      ad.apply(
        rest.map((x) =>
          ad.movePatch(x.raw, pushed.has(x.view.id) ? x.view.start + delta : x.view.start)
        )
      );
      ui.onDrag({ kind, id, targetRow, ghostX: ds * ui.pps, slotStart: clamped, len });
    },
    onUp: (_dx, _dy, moved) => {
      ui.vertical?.setActive?.(false);
      ui.onSnap(null);
      ui.onDrag(null);
      if (live && refDrag?.drop()) {
        // A reference zone took the asset; undo every transient slide.
        restRestore();
        ui.vertical?.preview(null, 0, 0);
        return;
      }
      if (ui.vertical && awayTarget !== null && !ui.vertical.isHome(awayTarget)) {
        ui.vertical.commit(id, awayTarget, ds);
        return;
      }
      if (!live || !moved) return;
      ad.apply([ad.movePatch(raw0, slotStart)]);
      commitRow(kind, id, targetRow);
      ad.onMoved?.();
    },
  });
}

/** Land a dragged item on a display row: a row past the end becomes a
 * brand-new track after the current max, then lanes renumber to stay
 * contiguous so empty tracks collapse. The move's pointer-down already
 * checkpointed history, so the whole gesture is one undo step. */
function commitRow(kind: LaneKind, id: string, targetRow: number) {
  const s = useEditor.getState();
  const ad = ADAPTERS[kind];
  if (!ad.multiLane || !ad.lanePatch) return;
  const raws = ad.raws(s);
  const views = raws.map((r) => ad.view(r));
  const used = [...new Set(views.map((v) => v.lane))].sort((a, b) => a - b);
  const cur = views.find((v) => v.id === id);
  if (!cur || targetRow === used.indexOf(cur.lane)) return;
  const lane = targetRow < used.length ? used[targetRow] : (used[used.length - 1] ?? -1) + 1;
  const moved = views.map((v) => (v.id === id ? lane : v.lane));
  const usedNext = [...new Set(moved)].sort((a, b) => a - b);
  const remap = new Map(usedNext.map((l, i) => [l, i]));
  ad.apply(raws.map((r, i) => ad.lanePatch!(r, remap.get(moved[i]) ?? 0)));
}

export interface LaneTrimUI {
  pps: number;
  /** Paint (or clear) the snap guide at this stage-x pixel. */
  onSnap(x: number | null): void;
}

/** Resize an item from either edge, with snapping, neighbor pushing, source
 * bounds for media, and the rubber-band + spring-back left-edge floor. */
export function startLaneTrim(
  e: React.PointerEvent,
  kind: LaneKind,
  id: string,
  side: "l" | "r",
  ui: LaneTrimUI
) {
  cancelAnimationFrame(snapBackRaf);
  const s = useEditor.getState();
  const ad = ADAPTERS[kind];
  const raw0 = ad.raws(s).find((r) => ad.view(r).id === id);
  if (!raw0) return;
  const self = ad.view(raw0);
  s.select({ kind, id } as Selection);
  s.pushHistory();
  const targets = snapTargets(s, kind, id);
  const tol = SNAP_PX / ui.pps;
  const sameLane = ad
    .raws(s)
    .map((r) => ({ raw: r, view: ad.view(r) }))
    .filter((x) => x.view.id !== id && x.view.lane === self.lane);

  if (side === "l") {
    const start0 = self.start;
    const maxStart = start0 + self.len - ad.minLen;
    // Items before this one, at their original spots. The edge grows freely
    // into the open gap; past the neighbor it shoves the run left, closing
    // gap after gap until everything sits flush against 0 — plus a media
    // item's own floor: the edge can't reveal earlier than its first sample.
    const leaders = sameLane
      .filter((x) => x.view.start + x.view.len <= start0 + 1e-3)
      .sort((a, b) => a.view.start - b.view.start);
    const prevEnd = leaders.reduce((m, l) => Math.max(m, l.view.start + l.view.len), 0);
    const runFloor = leaders.reduce((sum, l) => sum + l.view.len, 0);
    const floor = Math.max(runFloor, ad.leftFloor(raw0));
    const free = Math.max(prevEnd, ad.leftFloor(raw0));
    startDrag(e, {
      onMove: (dx, _dy, ev) => {
        cancelAnimationFrame(snapBackRaf);
        const desired = Math.min(maxStart, start0 + dx / ui.pps);
        let start: number;
        if (desired >= free) {
          // Room to the left: grow freely, snapping to logical times.
          start = desired;
          const hit = ev.metaKey ? null : nearestSnap(start, targets, tol);
          if (hit !== null && hit >= free && hit <= maxStart) {
            start = hit;
            ui.onSnap(leftGuide(hit, ui.pps));
          } else ui.onSnap(null);
        } else {
          // Pushing: past the floor it drags with resistance and springs back.
          start =
            desired >= floor
              ? desired
              : Math.max(
                  0,
                  floor - rubberBand((floor - desired) * ui.pps, LEFT_RUBBER_PX) / ui.pps
                );
          ui.onSnap(null);
        }
        // Re-lay the leaders right-to-left from their resting spots: each one
        // slides only as far as the pushed edge (or the item it now abuts)
        // forces it, so a retreating drag lets the run flow back.
        const patches = [ad.trimLeftPatch(raw0, start)];
        let limit = Math.max(start, runFloor);
        for (let i = leaders.length - 1; i >= 0; i--) {
          const l = leaders[i];
          const end = Math.min(l.view.start + l.view.len, limit);
          patches.push(ad.movePatch(l.raw, end - l.view.len));
          limit = end - l.view.len;
        }
        ad.apply(patches);
      },
      onUp: () => {
        ui.onSnap(null);
        const cur = ad.raws(useEditor.getState()).find((r) => ad.view(r).id === id);
        const from = cur ? ad.view(cur).start : floor;
        if (from >= floor - 1e-4) return; // settled within the room
        // Elastic spring back to the floor.
        const t0 = performance.now();
        const step = (now: number) => {
          const p = Math.min(1, (now - t0) / 240);
          const v = Math.max(0, from + (floor - from) * easeOutBack(p));
          ad.apply([ad.trimLeftPatch(raw0, p < 1 ? v : floor)]);
          if (p < 1) snapBackRaf = requestAnimationFrame(step);
        };
        snapBackRaf = requestAnimationFrame(step);
      },
    });
    return;
  }

  const end0 = self.start + self.len;
  const minEnd = self.start + ad.minLen;
  const maxEnd = self.start + ad.maxLen(s, raw0);
  // Items after this one, at their original spots: extending the edge past
  // the first of them pushes the whole run right (their gaps preserved);
  // pulling back lets them return.
  const followers = sameLane
    .filter((x) => x.view.start >= self.start)
    .sort((a, b) => a.view.start - b.view.start);
  const nextStart = followers.length ? followers[0].view.start : Infinity;
  startDrag(e, {
    onMove: (dx, _dy, ev) => {
      let end = Math.max(minEnd, Math.min(maxEnd, end0 + dx / ui.pps));
      const hit = ev.metaKey ? null : nearestSnap(end, targets, tol);
      if (hit !== null && hit > minEnd && hit <= maxEnd) {
        end = hit;
        ui.onSnap(rightGuide(end, ui.pps));
      } else ui.onSnap(null);
      const delta = Math.max(0, end - nextStart);
      ad.apply([
        ad.trimRightPatch(raw0, end),
        ...followers.map((f) => ad.movePatch(f.raw, f.view.start + delta)),
      ]);
    },
    onUp: () => ui.onSnap(null),
  });
}
