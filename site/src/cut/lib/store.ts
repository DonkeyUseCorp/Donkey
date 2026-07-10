"use client";

import { create } from "zustand";
import type {
  Aspect,
  AudioClip,
  ClipSpan,
  LibraryTemplate,
  MediaAsset,
  OverlayClip,
  ProjectDoc,
  Selection,
  StoredAsset,
  SubtitleCue,
  SubtitlesBlock,
  TemplateAudio,
  TemplateLayer,
  TemplateMedia,
  TemplateSaveInput,
  TextOverlay,
  TransitionStyle,
  VideoClip,
} from "./types";
import { apiFetch, apiJson } from "./api";
import { emptySubtitles, isCrossStyle, mediaUrl, SPEED_MAX, SPEED_MIN, TRANSITION_MAX } from "./types";
import { readTextStyle } from "./textStyle";
import { loadUiState, saveUiState } from "./uiState";
import { captureTimelineFrames } from "./visualFrames";

const uid = () => crypto.randomUUID().slice(0, 8);

const MIN_LEN = 0.1;

/** Where a video clip lands when dropped: an existing track, the magnetic base
 * row, or a brand-new track inserted at z-level `level`. Track numbers are
 * signed: positive tracks sit above the base (higher = closer to the top),
 * negative tracks sit below it (more negative = further behind), base is 0.
 * Inserting shifts the tracks past `level` (up for positive, down for negative)
 * to open the slot. */
export type VideoTrackPlacement =
  | { kind: "track"; track: number }
  | { kind: "base" }
  | { kind: "insert"; level: number };

/** Open a slot at `level`, moving other clips out of the way: above the base
 * (level > 0) shifts tracks at/above it up; below the base (level < 0) shifts
 * tracks at/below it down. `exclude` is the clip being placed (left untouched). */
function openInsertSlot(clips: OverlayClip[], level: number, exclude?: string): OverlayClip[] {
  return level > 0
    ? clips.map((c) => (c.id !== exclude && c.track >= level ? { ...c, track: c.track + 1 } : c))
    : clips.map((c) => (c.id !== exclude && c.track <= level ? { ...c, track: c.track - 1 } : c));
}
const shiftTracksUp = (clips: OverlayClip[], place: VideoTrackPlacement): OverlayClip[] =>
  place.kind === "insert" ? openInsertSlot(clips, place.level) : clips;

/** A single-item selection: the primary that drives the Inspector plus the
 * one-element multiSelection that bulk actions (delete, copy) and the timeline
 * highlight read. Every mutation that selects its own result funnels through
 * this so the two can never drift apart. */
const sole = (sel: NonNullable<Selection>) => ({ selection: sel, multiSelection: [sel] });

export const TIMELINE_H_DEFAULT = 248;
export const TIMELINE_H_MIN = 170;
export const TIMELINE_H_MAX = 600;

interface DocSnapshot {
  clips: VideoClip[];
  audioClips: AudioClip[];
  overlayClips: OverlayClip[];
  overlays: TextOverlay[];
  subtitles: SubtitlesBlock;
}

export type SubtitleStatus = "idle" | "running" | "ready" | "empty" | "error";

export type SaveState = "saved" | "dirty" | "saving" | "error";

interface EditorState {
  projectId: string | null;
  projectName: string;
  loaded: boolean;
  loadError: string | null;
  saveState: SaveState;

  assets: MediaAsset[];
  clips: VideoClip[];
  audioClips: AudioClip[];
  /** Upper video tracks composited over the base track. */
  overlayClips: OverlayClip[];
  overlays: TextOverlay[];
  /** Output frame (9:16 vertical or 16:9 widescreen), persisted per project. */
  aspect: Aspect;
  /** Whole-video fades, seconds (0 = off): in from black at the start, out to
   * black at the end of the cut. Applied to the final picture and mix. */
  fadeIn: number;
  fadeOut: number;
  selection: Selection;
  /** Everything selected, including `selection` (the primary that drives the
   * inspector). Bulk actions — delete, copy — act on this whole set. */
  multiSelection: Selection[];
  currentTime: number;
  playing: boolean;
  pxPerSec: number;
  /** Timeline panel height in px (drag the panel's top border to change). */
  timelineH: number;
  /** Timeline time under the mouse (iMovie skimmer); null when off the timeline. */
  skimTime: number | null;
  /** TikTok publishing metadata (caption, hashtags, sound title). */
  publish: { caption: string; tags: string; soundTitle: string; handle: string };
  /** Free-form maker notes: published date, source links, reminders. */
  notes: { text: string; publishedAt: string; links: string[] };
  /** Subtitles: cues + visibility, persisted with the project. */
  subtitles: SubtitlesBlock;
  subtitleStatus: SubtitleStatus;
  subtitleError: string | null;
  exportOpen: boolean;
  dropActive: boolean;
  /** Whether the AI assistant panel is open (remembered across sessions). */
  aiOpen: boolean;

  loadProject: (id: string) => Promise<void>;
  setProjectName: (name: string) => void;
  setSaveState: (s: SaveState) => void;

  setAspect: (a: Aspect) => void;
  /** Set the whole-video fade in/out (seconds; 0 clears). Like the aspect,
   * project-level settings sit outside the undo history. */
  setProjectFade: (patch: { fadeIn?: number; fadeOut?: number }) => void;
  addAsset: (asset: MediaAsset) => void;
  updateAsset: (id: string, patch: Partial<MediaAsset>) => void;
  /** Remove a project asset and any clips/audio that reference it. */
  removeAsset: (id: string) => void;
  /** Add a video clip from an asset. With `index`, insert at that position on
   * the magnetic video track; otherwise append. */
  addClipFromAsset: (assetId: string, index?: number) => void;
  /** Add a soundtrack clip from an audio asset at `start` (default: the
   * playhead). `opts.duck` marks it a voiceover that lowers everything else
   * to that gain while it plays. */
  addAudioFromAsset: (assetId: string, start?: number, opts?: { duck?: number }) => void;
  addOverlay: () => void;
  /** Move a title to a title track (row); lanes are renumbered to stay
   * contiguous, so empty tracks collapse and a past-the-end lane adds one. */
  moveOverlayToLane: (id: string, lane: number) => void;
  updateClip: (id: string, patch: Partial<VideoClip>) => void;
  /** Set a clip's playback rate (0.25–4). The clip's timeline footprint
   * changes, so later titles/captions ripple to stay in sync. */
  setClipSpeed: (id: string, speed: number) => void;
  /** Set the transition into the next clip (seconds; 0 clears it), optionally
   * changing its style; omitting the style keeps the clip's current one. */
  setClipTransition: (id: string, seconds: number, style?: TransitionStyle) => void;
  updateAudio: (id: string, patch: Partial<AudioClip>) => void;
  updateOverlay: (id: string, patch: Partial<TextOverlay>) => void;
  /** Live-drag updates that should not create undo entries. */
  updateOverlayTransient: (id: string, patch: Partial<TextOverlay>) => void;
  /** Patch several titles in one commit (ripple resize pushes a whole lane). */
  updateOverlaysTransient: (patches: { id: string; patch: Partial<TextOverlay> }[]) => void;
  updateClipTransient: (id: string, patch: Partial<VideoClip>) => void;
  updateAudioTransient: (id: string, patch: Partial<AudioClip>) => void;
  moveClip: (id: string, toIndex: number) => void;
  /** Add a video asset to the timeline at a placement: an upper track, the base
   * row, or a freshly inserted track. Used by media / library drops. */
  addVideoFromAsset: (assetId: string, place: VideoTrackPlacement, start: number) => void;
  /** Move an existing clip (base or upper) to a placement, preserving its
   * trim/region/speed. Inserting a track renumbers the ones above it; dropping on
   * the base row converts it back to a magnetic clip. Owns its own history. */
  dropVideoClip: (
    source: { kind: "base" | "overlay"; id: string },
    place: VideoTrackPlacement,
    start: number
  ) => void;
  updateOverlayClip: (id: string, patch: Partial<OverlayClip>) => void;
  updateOverlayClipTransient: (id: string, patch: Partial<OverlayClip>) => void;
  /** iMovie "Detach Audio": lift the selected clip's sound onto the
   * soundtrack track (and mute the clip) so it can be cut independently. */
  detachAudio: () => void;
  /** Split at the given time, or the playhead when omitted. */
  splitAtPlayhead: (at?: number) => void;
  setSkimTime: (t: number | null) => void;
  setPublish: (patch: Partial<{ caption: string; tags: string; soundTitle: string; handle: string }>) => void;
  setNotes: (patch: Partial<{ text: string; publishedAt: string; links: string[] }>) => void;
  /** Kick off (and poll) an on-device transcription of the current cut. */
  generateSubtitles: () => Promise<void>;
  /** Caption the cut from its picture alone (no audio needed): sample frames
   * along the timeline and have the AI write timed narration cues. */
  generateVisualSubtitles: () => Promise<void>;
  /** Transcribe (if needed) then rewrite the cues into social captions in the
   * given style, one-to-one so cue timings are preserved. */
  generateCaptions: (style: "clean" | "hook" | "punchy") => Promise<void>;
  setSubtitlesView: (patch: Partial<Pick<SubtitlesBlock, "showOnVideo" | "showOnTimeline" | "locale" | "style" | "x" | "y" | "wordHighlight" | "accentMode" | "accentColor">>) => void;
  /** Commit a cue's edited text (empty text deletes the cue). */
  setCueText: (id: string, text: string) => void;
  /** Split a cue at a character offset — at real word timings when known. */
  splitCue: (id: string, charOffset: number) => void;
  mergeCueIntoPrev: (id: string) => void;
  deleteCue: (id: string) => void;
  updateCueTransient: (id: string, patch: Partial<SubtitleCue>) => void;
  /** Re-time listed cues to a generated voiceover: set each cue's [start, end]
   * and spread its words across the new span (the AI voice paces differently
   * from the original recording, so the word highlighter would otherwise drift). */
  retimeCues: (entries: { id: string; start: number; end: number }[]) => void;
  sortCues: () => void;
  deleteSelection: () => void;
  /** Timeline window [start, end) spanned by the current selection, or null if
   * nothing selectable is chosen. */
  selectionRange: () => { start: number; end: number } | null;
  /** Build a by-reference template from the current selection (media + the edit
   * that arranges it, rebased to 0), or null if nothing usable is selected. */
  selectionTemplate: () => TemplateSaveInput | null;
  /** Re-materialize a template into the project at `offset` seconds. `assetIds`
   * maps each `template.media` index to a freshly-added project asset id. */
  insertTemplate: (template: LibraryTemplate, assetIds: string[], offset: number) => void;
  select: (sel: Selection) => void;
  /** ⌘/⇧-click: add the item to the selection (or remove it if already in),
   * making it the new primary. */
  toggleSelect: (sel: NonNullable<Selection>) => void;
  /** Shift every free-positioned title and subtitle cue starting at or after
   * `afterTime` by `delta` seconds (clamped to ≥0). Keeps annotations synced
   * when the video track's length changes upstream. Caller owns the history
   * checkpoint. */
  rippleShift: (afterTime: number, delta: number) => void;
  seek: (t: number) => void;
  setPlaying: (p: boolean) => void;
  setPxPerSec: (v: number) => void;
  setTimelineH: (h: number) => void;
  setExportOpen: (v: boolean) => void;
  setDropActive: (v: boolean) => void;
  setAiOpen: (v: boolean) => void;
  undo: () => void;
  redo: () => void;
  pushHistory: () => void;
  /** Coalesce every edit until the matching `endHistoryBatch` into one undo
   * step. Used so a whole assistant turn reverts with a single ⌘Z. */
  beginHistoryBatch: () => void;
  endHistoryBatch: () => void;
  /** Copy the selected clip/audio/overlay/title(s) to the timeline clipboard. */
  copySelection: () => boolean;
  /** Paste the clipboard at the playhead — sliding past anything already on
   * the target lane — and select the pasted item(s). */
  paste: () => boolean;
}

// Per-project undo/redo stacks; both reset when a project loads. Capped so a
// long session (each snapshot deep-copies every clip/cue) can't grow unbounded.
const HISTORY_CAP = 100;
const history: DocSnapshot[] = [];
const future: DocSnapshot[] = [];
/** A checkpoint captured on pointerdown/focus but not yet committed: it lands
 * in `history` only once an edit actually follows (see flush), so a bare
 * click-to-select never records a no-op snapshot or clears the redo branch. */
let pending: { snap: DocSnapshot; seq: number } | null = null;
/** Bumped whenever the persistable doc actually changes, letting a pending
 * checkpoint tell a real edit apart from a select/seek that touched nothing. */
let docSeq = 0;
/** >0 while a run of edits is being coalesced into one undo step (see
 * beginHistoryBatch). One checkpoint is captured when it goes 0→1. */
let batchDepth = 0;

/** Timeline clipboard (⌘C/⌘V) — survives across projects in one session. One
 * entry per copied item so a multi-selection round-trips. */
type ClipboardItem =
  | { kind: "clip"; item: VideoClip }
  | { kind: "audio"; item: AudioClip }
  | { kind: "overlayClip"; item: OverlayClip }
  | { kind: "text"; item: TextOverlay };
let clipboard: ClipboardItem[] = [];

/** Earliest start at/after `t` where a `len`-long item fits between the
 * occupied `spans` of one lane: each blocker slides the candidate right to its
 * end until a big-enough gap opens. */
function nextFreeStart(spans: { start: number; end: number }[], t: number, len: number): number {
  const sorted = [...spans].sort((a, b) => a.start - b.start);
  let at = t;
  for (const sp of sorted) {
    if (sp.end <= at + 1e-3) continue;
    if (sp.start >= at + len - 1e-3) break;
    at = sp.end;
  }
  return at;
}

export const useEditor = create<EditorState>((set, get) => {
  const snapshot = (): DocSnapshot => {
    const { clips, audioClips, overlayClips, overlays, subtitles } = get();
    return {
      clips: clips.map((c) => ({ ...c })),
      audioClips: audioClips.map((c) => ({ ...c })),
      overlayClips: overlayClips.map((c) => ({ ...c })),
      overlays: overlays.map((o) => ({ ...o })),
      subtitles: {
        ...subtitles,
        cues: subtitles.cues.map((c) => ({ ...c, words: c.words?.map((w) => ({ ...w })) })),
      },
    };
  };

  /** Seal the deferred checkpoint: commit it to history only if the doc
   * changed since it was taken; otherwise drop it and leave redo intact. */
  const flush = () => {
    if (!pending) return;
    const p = pending;
    pending = null;
    if (docSeq !== p.seq) {
      history.push(p.snap);
      if (history.length > HISTORY_CAP) history.shift();
      future.length = 0; // a real edit invalidates the redo branch
    }
  };

  const push = () => {
    // Inside a batch a single checkpoint (taken at beginHistoryBatch) already
    // covers every edit, so individual pushes are no-ops.
    if (batchDepth > 0) return;
    flush(); // seal the previous edit's checkpoint before starting a new one
    pending = { snap: snapshot(), seq: docSeq };
  };

  return {
    projectId: null,
    projectName: "",
    loaded: false,
    loadError: null,
    saveState: "saved",

    assets: [],
    clips: [],
    audioClips: [],
    overlayClips: [],
    overlays: [],
    aspect: "9:16",
    fadeIn: 0,
    fadeOut: 0,
    selection: null,
    multiSelection: [],
    currentTime: 0,
    playing: false,
    pxPerSec: 60,
    timelineH: TIMELINE_H_DEFAULT,
    skimTime: null,
    publish: { caption: "", tags: "", soundTitle: "", handle: "" },
    notes: { text: "", publishedAt: "", links: [] },
    subtitles: emptySubtitles(),
    subtitleStatus: "idle",
    subtitleError: null,
    exportOpen: false,
    dropActive: false,
    aiOpen: typeof window !== "undefined" && localStorage.getItem("cut-ai-open") === "1",

    loadProject: async (id) => {
      history.length = 0;
      future.length = 0;
      pending = null;
      set({
        projectId: id,
        loaded: false,
        loadError: null,
        saveState: "saved",
        assets: [],
        clips: [],
        audioClips: [],
        overlayClips: [],
        overlays: [],
        aspect: "9:16",
        fadeIn: 0,
        fadeOut: 0,
        selection: null,
        multiSelection: [],
        currentTime: 0,
        playing: false,
        subtitles: emptySubtitles(),
        subtitleStatus: "idle",
        subtitleError: null,
        exportOpen: false,
      });
      try {
        const [res, ui] = await Promise.all([apiFetch(`/api/cut/projects/${id}`), loadUiState(id)]);
        if (!res.ok) throw new Error("This project no longer exists.");
        const doc = (await res.json()) as ProjectDoc;
        const assets: MediaAsset[] = doc.assets.map((a) => ({
          ...a,
          url: mediaUrl(id, a.fileName),
        }));
        set({
          projectName: doc.name,
          assets,
          clips: doc.clips,
          audioClips: doc.audioClips,
          overlayClips: doc.overlayClips ?? [],
          overlays: doc.overlays,
          aspect: doc.aspect ?? "9:16",
          fadeIn: doc.fadeIn ?? 0,
          fadeOut: doc.fadeOut ?? 0,
          // View state lives in IndexedDB; doc.ui covers projects saved
          // before the move.
          pxPerSec: Math.max(12, Math.min(800, ui.pxPerSec ?? doc.ui?.pxPerSec ?? 60)),
          timelineH: Math.max(
            TIMELINE_H_MIN,
            Math.min(TIMELINE_H_MAX, ui.timelineH ?? TIMELINE_H_DEFAULT)
          ),
          publish: {
            caption: doc.publish?.caption ?? "",
            tags: doc.publish?.tags ?? "",
            soundTitle: doc.publish?.soundTitle ?? "",
            handle: doc.publish?.handle ?? "",
          },
          notes: {
            text: doc.notes?.text ?? "",
            publishedAt: doc.notes?.publishedAt ?? "",
            links: doc.notes?.links ?? [],
          },
          subtitles: doc.subtitles ?? emptySubtitles(),
          subtitleStatus: (doc.subtitles?.cues.length ?? 0) > 0 ? "ready" : "idle",
          loaded: true,
        });
      } catch (err) {
        set({ loadError: err instanceof Error ? err.message : String(err) });
      }
    },

    setProjectName: (name) => set({ projectName: name }),
    setSaveState: (s) => set({ saveState: s }),

    pushHistory: push,

    beginHistoryBatch: () => {
      if (batchDepth === 0) {
        flush(); // seal any prior edit before opening the batch
        pending = { snap: snapshot(), seq: docSeq };
      }
      batchDepth++;
    },
    endHistoryBatch: () => {
      batchDepth = Math.max(0, batchDepth - 1);
      if (batchDepth === 0) flush(); // commit the whole run as one undo step
    },

    setAspect: (a) => set({ aspect: a }),
    setProjectFade: (patch) => {
      const clamp = (v: number | undefined) =>
        v === undefined ? undefined : Math.max(0, Math.min(TRANSITION_MAX, v));
      set((s) => ({
        fadeIn: clamp(patch.fadeIn) ?? s.fadeIn,
        fadeOut: clamp(patch.fadeOut) ?? s.fadeOut,
      }));
    },

    addAsset: (asset) =>
      set((s) => {
        // The first video in an untouched project decides the starting frame
        // (landscape footage → 16:9, portrait → 9:16); the user can switch it
        // any time from the top bar.
        const guess =
          asset.type === "video" &&
          asset.width !== undefined &&
          asset.height !== undefined &&
          s.clips.length === 0 &&
          !s.assets.some((a) => a.type === "video")
            ? asset.width >= asset.height
              ? ("16:9" as Aspect)
              : ("9:16" as Aspect)
            : null;
        return { assets: [...s.assets, asset], ...(guess ? { aspect: guess } : {}) };
      }),

    updateAsset: (id, patch) =>
      set((s) => ({
        assets: s.assets.map((a) => (a.id === id ? { ...a, ...patch } : a)),
      })),

    removeAsset: (id) => {
      const st = get();
      if (!st.assets.some((a) => a.id === id)) return;
      push();
      // Cascade removes this asset's clips; ripple later annotations so they
      // stay aligned with the content that survives.
      const bump = makeRipple(st.clips, st.clips.filter((c) => c.assetId !== id), st.assets);
      set((s) => {
        const goneClips = new Set(s.clips.filter((c) => c.assetId === id).map((c) => c.id));
        const goneAudio = new Set(s.audioClips.filter((c) => c.assetId === id).map((c) => c.id));
        const keep = (sel: Selection) =>
          !!sel &&
          !((sel.kind === "clip" && goneClips.has(sel.id)) ||
            (sel.kind === "audio" && goneAudio.has(sel.id)));
        const multiSelection = s.multiSelection.filter(keep);
        return {
          assets: s.assets.filter((a) => a.id !== id),
          clips: s.clips.filter((c) => c.assetId !== id),
          audioClips: s.audioClips.filter((c) => c.assetId !== id),
          overlays: s.overlays.map(bump),
          subtitles: { ...s.subtitles, cues: s.subtitles.cues.map(bump) },
          multiSelection,
          selection: keep(s.selection) ? s.selection : multiSelection[multiSelection.length - 1] ?? null,
        };
      });
    },

    addClipFromAsset: (assetId, index) => {
      const asset = get().assets.find((a) => a.id === assetId);
      if (!asset || asset.type !== "video") return;
      push();
      const clip: VideoClip = {
        id: uid(),
        assetId,
        in: 0,
        out: asset.duration,
        muted: false,
      };
      set((s) => {
        const at =
          index === undefined ? s.clips.length : Math.max(0, Math.min(index, s.clips.length));
        const clips = [...s.clips];
        clips.splice(at, 0, clip);
        return { clips, ...sole({ kind: "clip", id: clip.id }) };
      });
    },

    addAudioFromAsset: (assetId, start, opts) => {
      const asset = get().assets.find((a) => a.id === assetId);
      if (!asset || asset.type !== "audio") return;
      push();
      const clip: AudioClip = {
        id: uid(),
        assetId,
        start: Math.max(0, start ?? get().currentTime),
        in: 0,
        out: asset.duration,
        volume: 1,
        ...(opts?.duck !== undefined && opts.duck < 1
          ? { duck: Math.max(0, opts.duck) }
          : {}),
      };
      set((s) => ({
        audioClips: [...s.audioClips, clip],
        ...sole({ kind: "audio", id: clip.id }),
      }));
    },

    addOverlay: () => {
      push();
      const t = get().currentTime;
      const total = totalDuration(get().clips);
      const start = Math.min(t, Math.max(0, total - 0.5));
      // Seed the visual style from the last-used title so repeated titles in a
      // project share one look; fall back to the built-in defaults.
      const remembered = readTextStyle();
      const overlay: TextOverlay = {
        id: uid(),
        text: "Your text",
        start,
        end: Math.min(start + 3, Math.max(total, start + 3)),
        x: 0.5,
        y: 0.42,
        size: remembered.size ?? 88,
        font: remembered.font ?? "sf",
        weight: remembered.weight ?? 700,
        color: remembered.color ?? "#FFFFFF",
        shadow: remembered.shadow ?? true,
        plate: remembered.plate ?? false,
        plateColor: remembered.plateColor,
        plateOpacity: remembered.plateOpacity,
        plateRadius: remembered.plateRadius,
        lane: 0,
      };
      set((s) => ({
        overlays: [...s.overlays, overlay],
        ...sole({ kind: "text", id: overlay.id }),
      }));
    },

    moveOverlayToLane: (id, lane) => {
      const overlays = get().overlays;
      if (!overlays.some((o) => o.id === id)) return;
      // No checkpoint here: the drag gesture that calls this already pushed
      // one at pointer-down, so the whole move is a single undo step.
      // Drop the title on the target row, then renumber so lanes stay
      // contiguous — empty tracks vanish, and a past-the-end target becomes a
      // fresh top-numbered track.
      const moved = overlays.map((o) => (o.id === id ? { ...o, lane } : o));
      const used = [...new Set(moved.map((o) => o.lane ?? 0))].sort((a, b) => a - b);
      const remap = new Map(used.map((l, i) => [l, i]));
      set({ overlays: moved.map((o) => ({ ...o, lane: remap.get(o.lane ?? 0) ?? 0 })) });
    },

    // The non-transient updaters are just a checkpoint plus the live update.
    updateClip: (id, patch) => {
      push();
      get().updateClipTransient(id, patch);
    },

    setClipSpeed: (id, speed) => {
      const s = get();
      const clip = s.clips.find((c) => c.id === id);
      if (!clip) return;
      const clamped = Math.max(SPEED_MIN, Math.min(SPEED_MAX, speed));
      if (Math.abs(clamped - clipSpeed(clip)) < 1e-4) return;
      const span = getClipSpans(s.clips, s.assets).find((sp) => sp.clip.id === id);
      const oldLen = span?.len ?? clipLen(clip);
      const newLen = Math.max(MIN_LEN, (clip.out - clip.in) / clamped);
      const editEnd = (span?.start ?? 0) + oldLen;
      push();
      get().updateClipTransient(id, { speed: clamped });
      get().rippleShift(editEnd, newLen - oldLen);
    },

    setClipTransition: (id, seconds, style) => {
      const s = get();
      const idx = s.clips.findIndex((c) => c.id === id);
      if (idx < 0) return;
      const clip = s.clips[idx];
      const next = s.clips[idx + 1];
      const value = Math.max(0, Math.min(TRANSITION_MAX, seconds));
      const newStyle = value > 0 ? (style ?? clip.transitionStyle ?? "crossfade") : undefined;
      const oldOverlap = transitionOverlap(clip, next);
      const newOverlap = transitionOverlap(
        { ...clip, transition: value, transitionStyle: newStyle },
        next
      );
      const span = getClipSpans(s.clips, s.assets).find((sp) => sp.clip.id === id);
      const editEnd = (span?.start ?? 0) + (span?.len ?? clipLen(clip));
      push();
      get().updateClipTransient(id, {
        transition: value || undefined,
        // "crossfade" is the default — store it as absence to keep docs lean.
        transitionStyle: newStyle === "crossfade" ? undefined : newStyle,
      });
      get().rippleShift(editEnd, oldOverlap - newOverlap);
    },

    updateAudio: (id, patch) => {
      push();
      get().updateAudioTransient(id, patch);
    },
    updateOverlay: (id, patch) => {
      push();
      get().updateOverlayTransient(id, patch);
    },

    updateOverlayTransient: (id, patch) =>
      set((s) => ({
        overlays: s.overlays.map((o) => (o.id === id ? { ...o, ...patch } : o)),
      })),

    updateOverlaysTransient: (patches) =>
      set((s) => {
        const byId = new Map(patches.map((p) => [p.id, p.patch]));
        return {
          overlays: s.overlays.map((o) => {
            const patch = byId.get(o.id);
            return patch ? { ...o, ...patch } : o;
          }),
        };
      }),

    updateClipTransient: (id, patch) =>
      set((s) => ({
        clips: s.clips.map((c) => (c.id === id ? { ...c, ...patch } : c)),
      })),

    updateAudioTransient: (id, patch) =>
      set((s) => ({
        audioClips: s.audioClips.map((c) =>
          c.id === id ? { ...c, ...patch } : c
        ),
      })),

    moveClip: (id, toIndex) => {
      const { clips } = get();
      const from = clips.findIndex((c) => c.id === id);
      if (from < 0) return;
      const to = Math.max(0, Math.min(clips.length - 1, toIndex));
      if (to === from) return;
      push();
      const next = [...clips];
      const [moved] = next.splice(from, 1);
      next.splice(to, 0, moved);
      set({ clips: next });
    },

    addVideoFromAsset: (assetId, place, start) => {
      const asset = get().assets.find((a) => a.id === assetId);
      if (!asset || asset.type !== "video") return;
      push();
      if (place.kind === "base") {
        const v: VideoClip = { id: uid(), assetId, in: 0, out: asset.duration, muted: false };
        set((s) => {
          const spans = getClipSpans(s.clips, s.assets);
          const at = spans.filter((sp) => sp.start + sp.len / 2 <= start).length;
          const clips = [...s.clips];
          clips.splice(Math.max(0, Math.min(at, clips.length)), 0, v);
          return { clips, ...sole({ kind: "clip", id: v.id }) };
        });
        return;
      }
      // Full-frame by default: covers the base ("topmost plays"); the inspector
      // regions it (split half / corner PiP).
      const track = place.kind === "insert" ? place.level : place.track;
      const ov: OverlayClip = {
        id: uid(),
        assetId,
        track,
        start: Math.max(0, start),
        in: 0,
        out: asset.duration,
        muted: false,
      };
      set((s) => ({
        overlayClips: [...shiftTracksUp(s.overlayClips, place), ov],
        ...sole({ kind: "overlayClip", id: ov.id }),
      }));
    },

    dropVideoClip: (source, place, start) => {
      const s = get();
      const src =
        source.kind === "base"
          ? s.clips.find((c) => c.id === source.id)
          : s.overlayClips.find((c) => c.id === source.id);
      if (!src) return;
      // Overlay source already snapshotted history on drag-start (it live-moved);
      // a base source hasn't been mutated yet, so snapshot now.
      if (source.kind === "base") push();
      const v = {
        assetId: src.assetId,
        in: src.in,
        out: src.out,
        muted: src.muted,
        hidden: src.hidden,
        frame: src.frame,
        fit: src.fit,
        speed: src.speed,
      };

      if (place.kind === "base") {
        if (source.kind === "base") return; // base reorder is handled by moveClip
        const clip: VideoClip = { id: uid(), ...v };
        set((st) => {
          const spans = getClipSpans(st.clips, st.assets);
          const at = spans.filter((sp) => sp.start + sp.len / 2 <= start).length;
          const clips = [...st.clips];
          clips.splice(Math.max(0, Math.min(at, clips.length)), 0, clip);
          return {
            clips,
            overlayClips: st.overlayClips.filter((c) => c.id !== source.id),
            ...sole({ kind: "clip", id: clip.id }),
          };
        });
        return;
      }

      const track = place.kind === "insert" ? place.level : place.track;
      if (source.kind === "overlay") {
        set((st) => {
          const shifted =
            place.kind === "insert"
              ? openInsertSlot(st.overlayClips, place.level, source.id)
              : st.overlayClips;
          return {
            overlayClips: shifted.map((c) =>
              c.id === source.id ? { ...c, track, start: Math.max(0, start) } : c
            ),
            ...sole({ kind: "overlayClip", id: source.id }),
          };
        });
        return;
      }

      const ov: OverlayClip = { id: uid(), ...v, track, start: Math.max(0, start) };
      set((st) => ({
        clips: st.clips.filter((c) => c.id !== source.id),
        overlayClips: [...shiftTracksUp(st.overlayClips, place), ov],
        ...sole({ kind: "overlayClip", id: ov.id }),
      }));
    },

    updateOverlayClip: (id, patch) => {
      push();
      get().updateOverlayClipTransient(id, patch);
    },

    updateOverlayClipTransient: (id, patch) =>
      set((s) => ({
        overlayClips: s.overlayClips.map((c) => (c.id === id ? { ...c, ...patch } : c)),
      })),

    detachAudio: () => {
      const { clips, assets, selection } = get();
      if (selection?.kind !== "clip") return;
      const clip = clips.find((c) => c.id === selection.id);
      if (!clip || clip.muted) return; // no sound to detach
      const span = getClipSpans(clips, assets).find((sp) => sp.clip.id === clip.id);
      if (!span) return;
      push();
      const audio: AudioClip = {
        id: uid(),
        assetId: clip.assetId,
        start: span.start,
        in: clip.in,
        out: clip.out,
        volume: 1,
        // Carry the clip's rate so the detached track keeps the muted picture's
        // length and stays in sync (an AudioClip plays at its own `speed`).
        ...(clipSpeed(clip) !== 1 ? { speed: clipSpeed(clip) } : {}),
      };
      set((s) => ({
        audioClips: [...s.audioClips, audio],
        clips: s.clips.map((c) => (c.id === clip.id ? { ...c, muted: true } : c)),
        ...sole({ kind: "audio", id: audio.id }),
      }));
    },

    splitAtPlayhead: (at) => {
      const { clips, audioClips, assets, currentTime, selection } = get();
      const t = at ?? currentTime;

      // iMovie-style: with a soundtrack clip selected, ⌘B slices it instead.
      if (selection?.kind === "audio") {
        const a = audioClips.find((c) => c.id === selection.id);
        const len = a ? clipLen(a) : 0;
        if (a && t > a.start + 0.05 && t < a.start + len - 0.05) {
          push();
          const cutIn = a.in + (t - a.start);
          const left: AudioClip = { ...a, out: cutIn };
          const right: AudioClip = { ...a, id: uid(), start: t, in: cutIn };
          set((s) => {
            const idx = s.audioClips.findIndex((c) => c.id === a.id);
            const next = [...s.audioClips];
            next.splice(idx, 1, left, right);
            return { audioClips: next, ...sole({ kind: "audio", id: right.id }) };
          });
          return;
        }
      }

      // An overlay clip selected: slice it in place, like the base track.
      if (selection?.kind === "overlayClip") {
        const c = get().overlayClips.find((x) => x.id === selection.id);
        if (c) {
          const sp = c.speed && c.speed > 0 ? c.speed : 1;
          const eff = (c.out - c.in) / sp;
          if (t > c.start + 0.05 && t < c.start + eff - 0.05) {
            push();
            const cutIn = c.in + (t - c.start) * sp;
            const left: OverlayClip = { ...c, out: cutIn };
            const right: OverlayClip = { ...c, id: uid(), start: t, in: cutIn };
            set((s) => {
              const idx = s.overlayClips.findIndex((x) => x.id === c.id);
              const next = [...s.overlayClips];
              next.splice(idx, 1, left, right);
              return { overlayClips: next, ...sole({ kind: "overlayClip", id: right.id }) };
            });
          }
        }
        return;
      }

      const spans = getClipSpans(clips, assets);
      const span = spans.find(
        (sp) => t > sp.start + 0.05 && t < sp.start + sp.len - 0.05
      );
      if (!span) return;
      push();
      // Source time advances `speed`× faster than timeline time.
      const cutAt = span.clip.in + (t - span.start) * clipSpeed(span.clip);
      // The left half hard-cuts into the right; the right keeps the original
      // dissolve into whatever came after.
      const left: VideoClip = { ...span.clip, out: cutAt, transition: undefined, transitionStyle: undefined };
      const right: VideoClip = { ...span.clip, id: uid(), in: cutAt };
      set((s) => {
        const idx = s.clips.findIndex((c) => c.id === span.clip.id);
        const next = [...s.clips];
        next.splice(idx, 1, left, right);
        return { clips: next, ...sole({ kind: "clip", id: right.id }) };
      });
    },

    deleteSelection: () => {
      const st = get();
      const sels = st.multiSelection.length
        ? st.multiSelection
        : st.selection
          ? [st.selection]
          : [];
      if (sels.length === 0) return;
      push();
      const idsOf = (k: NonNullable<Selection>["kind"]) =>
        new Set(
          sels
            .filter((x): x is NonNullable<Selection> => !!x && x.kind === k)
            .map((x) => x.id)
        );
      const clipIds = idsOf("clip");
      const audioIds = idsOf("audio");
      const overlayClipIds = idsOf("overlayClip");
      const textIds = idsOf("text");
      const cueIds = idsOf("cue");
      // Removing video clips shortens the track; ripple later titles/captions
      // so they stay aligned with the content that survives.
      const bump = clipIds.size
        ? makeRipple(st.clips, st.clips.filter((c) => !clipIds.has(c.id)), st.assets)
        : <T extends { start: number; end: number }>(x: T): T => x;
      set((s) => ({
        clips: s.clips.filter((c) => !clipIds.has(c.id)),
        audioClips: s.audioClips.filter((c) => !audioIds.has(c.id)),
        overlayClips: s.overlayClips.filter((c) => !overlayClipIds.has(c.id)),
        overlays: s.overlays.filter((o) => !textIds.has(o.id)).map(bump),
        subtitles: {
          ...s.subtitles,
          cues: s.subtitles.cues.filter((c) => !cueIds.has(c.id)).map(bump),
        },
        selection: null,
        multiSelection: [],
      }));
    },

    selectionRange: () => {
      const s = get();
      const sels = (s.multiSelection.length ? s.multiSelection : s.selection ? [s.selection] : [])
        .filter((x): x is NonNullable<Selection> => !!x);
      if (sels.length === 0) return null;
      const spans = getClipSpans(s.clips, s.assets);
      let start = Infinity;
      let end = -Infinity;
      const add = (a: number, b: number) => {
        start = Math.min(start, a);
        end = Math.max(end, b);
      };
      for (const sel of sels) {
        if (sel.kind === "clip") {
          const sp = spans.find((x) => x.clip.id === sel.id);
          if (sp) add(sp.start, sp.start + sp.len);
        } else if (sel.kind === "overlayClip") {
          const c = s.overlayClips.find((x) => x.id === sel.id);
          if (c) {
            const sp = c.speed && c.speed > 0 ? c.speed : 1;
            add(c.start, c.start + Math.max(0.1, (c.out - c.in) / sp));
          }
        } else if (sel.kind === "audio") {
          const c = s.audioClips.find((x) => x.id === sel.id);
          if (c) add(c.start, c.start + clipLen(c));
        } else if (sel.kind === "text") {
          const o = s.overlays.find((x) => x.id === sel.id);
          if (o) add(o.start, o.end);
        } else if (sel.kind === "cue") {
          const c = s.subtitles.cues.find((x) => x.id === sel.id);
          if (c) add(c.start, c.end);
        }
      }
      return Number.isFinite(start) && end > start ? { start, end } : null;
    },

    selectionTemplate: () => {
      const s = get();
      const sels = (s.multiSelection.length ? s.multiSelection : s.selection ? [s.selection] : [])
        .filter((x): x is NonNullable<Selection> => !!x);
      if (sels.length === 0) return null;
      const range = get().selectionRange();
      const start0 = range ? range.start : 0;
      const spans = getClipSpans(s.clips, s.assets);

      // Media is referenced by array index; each source is listed once.
      const media: TemplateMedia[] = [];
      const indexByAsset = new Map<string, number>();
      const mediaFor = (assetId: string): number | null => {
        const cached = indexByAsset.get(assetId);
        if (cached != null) return cached;
        const a = s.assets.find((x) => x.id === assetId);
        if (!a) return null;
        const i = media.length;
        media.push({ fileName: a.fileName, name: a.name, type: a.type, duration: a.duration, width: a.width, height: a.height });
        indexByAsset.set(assetId, i);
        return i;
      };

      const layers: TemplateLayer[] = [];
      const audio: TemplateAudio[] = [];
      const texts: TextOverlay[] = [];
      const cues: SubtitleCue[] = [];
      for (const sel of sels) {
        if (sel.kind === "clip") {
          const sp = spans.find((x) => x.clip.id === sel.id);
          if (!sp) continue;
          const mi = mediaFor(sp.clip.assetId);
          if (mi == null) continue;
          // Base-track clips re-materialize onto the base track (onBase), so a
          // template stands up its own video instead of an empty base.
          layers.push({ media: mi, start: sp.start - start0, in: sp.clip.in, out: sp.clip.out, frame: sp.clip.frame, fit: sp.clip.fit, muted: sp.clip.muted, speed: sp.clip.speed, track: 1, onBase: true });
        } else if (sel.kind === "overlayClip") {
          const c = s.overlayClips.find((x) => x.id === sel.id);
          if (!c) continue;
          const mi = mediaFor(c.assetId);
          if (mi == null) continue;
          layers.push({ media: mi, start: c.start - start0, in: c.in, out: c.out, frame: c.frame, fit: c.fit, muted: c.muted, speed: c.speed, track: c.track + 1 });
        } else if (sel.kind === "audio") {
          const c = s.audioClips.find((x) => x.id === sel.id);
          if (!c) continue;
          const mi = mediaFor(c.assetId);
          if (mi == null) continue;
          audio.push({ media: mi, start: c.start - start0, in: c.in, out: c.out, volume: c.volume, fadeIn: c.fadeIn, fadeOut: c.fadeOut, speed: c.speed, duck: c.duck });
        } else if (sel.kind === "text") {
          const o = s.overlays.find((x) => x.id === sel.id);
          if (o) texts.push({ ...o, start: o.start - start0, end: o.end - start0 });
        } else if (sel.kind === "cue") {
          const c = s.subtitles.cues.find((x) => x.id === sel.id);
          if (c) cues.push({ ...c, start: c.start - start0, end: c.end - start0 });
        }
      }
      if (media.length === 0 && texts.length === 0 && cues.length === 0) return null;
      const duration = range
        ? range.end - range.start
        : Math.max(0.1, ...texts.map((t) => t.end), ...cues.map((c) => c.end));
      return { name: "Template", duration, media, layers, audio, texts, cues };
    },

    insertTemplate: (template, assetIds, offset) => {
      push();
      const usable = template.layers.filter((l) => assetIds[l.media]);
      const baseLayers = usable.filter((l) => l.onBase);
      const overlayLayers = usable.filter((l) => !l.onBase);
      // Base clips append (magnetic) at the end of the current base track; the
      // free-positioned parts (overlays, audio, captions) shift to line up with
      // that segment. A template with no base clips drops in at the playhead.
      const shift = baseLayers.length ? totalDuration(get().clips) : Math.max(0, offset);
      const newClips: VideoClip[] = [...baseLayers]
        .sort((a, b) => a.start - b.start)
        .map((l) => ({
          id: uid(),
          assetId: assetIds[l.media],
          in: l.in,
          out: l.out,
          muted: l.muted,
          ...(l.frame ? { frame: l.frame } : {}),
          ...(l.fit ? { fit: l.fit } : {}),
          ...(l.speed ? { speed: l.speed } : {}),
        }));
      const baseTrack = Math.max(0, ...get().overlayClips.map((c) => c.track));
      const newOverlays: OverlayClip[] = overlayLayers.map((l) => ({
        id: uid(),
        assetId: assetIds[l.media],
        track: baseTrack + l.track,
        start: l.start + shift,
        in: l.in,
        out: l.out,
        muted: l.muted,
        ...(l.frame ? { frame: l.frame } : {}),
        ...(l.fit ? { fit: l.fit } : {}),
        ...(l.speed ? { speed: l.speed } : {}),
      }));
      const newAudio: AudioClip[] = template.audio
        .filter((a) => assetIds[a.media])
        .map((a) => ({
          id: uid(),
          assetId: assetIds[a.media],
          start: a.start + shift,
          in: a.in,
          out: a.out,
          volume: a.volume,
          ...(a.fadeIn ? { fadeIn: a.fadeIn } : {}),
          ...(a.fadeOut ? { fadeOut: a.fadeOut } : {}),
          ...(a.speed ? { speed: a.speed } : {}),
          ...(a.duck !== undefined && a.duck < 1 ? { duck: a.duck } : {}),
        }));
      const newTexts: TextOverlay[] = template.texts.map((o) => ({
        ...o,
        id: uid(),
        start: o.start + shift,
        end: o.end + shift,
      }));
      const newCues: SubtitleCue[] = template.cues.map((c) => ({
        ...c,
        id: uid(),
        start: c.start + shift,
        end: c.end + shift,
      }));
      set((s) => ({
        clips: [...s.clips, ...newClips],
        overlayClips: [...s.overlayClips, ...newOverlays],
        audioClips: [...s.audioClips, ...newAudio],
        overlays: [...s.overlays, ...newTexts],
        subtitles: {
          ...s.subtitles,
          cues: [...s.subtitles.cues, ...newCues].sort((a, b) => a.start - b.start),
        },
      }));
    },

    select: (sel) => set({ selection: sel, multiSelection: sel ? [sel] : [] }),

    toggleSelect: (sel) =>
      set((s) => {
        const has = s.multiSelection.some((x) => x?.kind === sel.kind && x.id === sel.id);
        const next = has
          ? s.multiSelection.filter((x) => !(x?.kind === sel.kind && x.id === sel.id))
          : [...s.multiSelection, sel];
        // Primary is the just-added item, or the last survivor when removing.
        const primary = has ? next[next.length - 1] ?? null : sel;
        return { multiSelection: next, selection: primary };
      }),

    rippleShift: (afterTime, delta) => {
      if (delta === 0) return;
      set((s) => ({
        overlays: s.overlays.map((o) =>
          o.start >= afterTime - 0.001
            ? { ...o, start: Math.max(0, o.start + delta), end: Math.max(0, o.end + delta) }
            : o
        ),
        subtitles: {
          ...s.subtitles,
          cues: s.subtitles.cues.map((c) =>
            c.start >= afterTime - 0.001
              ? { ...c, start: Math.max(0, c.start + delta), end: Math.max(0, c.end + delta) }
              : c
          ),
        },
      }));
    },

    seek: (t) => {
      const total = projectDuration(get());
      set({ currentTime: Math.max(0, Math.min(total, t)) });
    },

    setPlaying: (p) => set({ playing: p }),
    setSkimTime: (t) => {
      if (get().skimTime !== t) set({ skimTime: t });
    },
    setPublish: (patch) => set((s) => ({ publish: { ...s.publish, ...patch } })),
    setNotes: (patch) => set((s) => ({ notes: { ...s.notes, ...patch } })),

    generateSubtitles: async () => {
      const s = get();
      if (!s.projectId || s.subtitleStatus === "running") return;
      const projectId = s.projectId;
      const spans = getClipSpans(s.clips, s.assets);
      if (spans.length === 0) {
        set({ subtitleStatus: "error", subtitleError: "Add a video to the timeline first." });
        return;
      }
      const duration = totalDuration(s.clips);
      const assetById = new Map(s.assets.map((a) => [a.id, a]));
      const spec = {
        duration,
        locale: s.subtitles.locale ?? "en-US",
        clips: spans.map((sp) => ({
          file: sp.asset.fileName,
          in: sp.clip.in,
          out: sp.clip.out,
          muted: sp.clip.muted,
          speed: clipSpeed(sp.clip),
          // The clamped cross-dissolve overlap, so the transcribe mix overlaps
          // clip audio the same way the timeline does and cues stay in sync.
          transition: sp.transitionOut,
        })),
        audio: s.audioClips
          .filter((a) => a.start < duration && assetById.has(a.assetId))
          .map((a) => ({
            file: assetById.get(a.assetId)!.fileName,
            in: a.in,
            out: a.out,
            start: a.start,
            volume: a.volume,
            speed: a.speed,
          })),
      };
      set({ subtitleStatus: "running", subtitleError: null });
      try {
        const res = await apiFetch(`/api/cut/projects/${projectId}/transcribe`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(spec),
        });
        const body = await apiJson<{ id?: string }>(res);
        if (!res.ok || !body.id) throw new Error(body.error ?? "Transcription failed to start.");
        for (;;) {
          await new Promise((r) => setTimeout(r, 600));
          if (get().projectId !== projectId) return; // switched projects mid-run
          const st = await apiFetch(`/api/cut/projects/${projectId}/transcribe?job=${body.id}`);
          if (!st.ok) throw new Error("The transcription job was lost — try again.");
          const status = (await st.json()) as {
            status: string;
            error?: string;
            cues?: SubtitleCue[];
          };
          if (status.status === "error") throw new Error(status.error ?? "Transcription failed.");
          if (status.status === "done") {
            if (get().projectId !== projectId) return;
            const cues = status.cues ?? [];
            if (cues.length === 0) {
              // No speech in the audio — leave the video untouched.
              set((cur) => ({
                subtitles: { ...cur.subtitles, cues: [], generatedAt: Date.now() },
                subtitleStatus: "empty",
              }));
              return;
            }
            push();
            set((cur) => ({
              subtitles: { ...cur.subtitles, cues, generatedAt: Date.now() },
              subtitleStatus: "ready",
            }));
            return;
          }
        }
      } catch (err) {
        if (get().projectId !== projectId) return;
        set({
          subtitleStatus: "error",
          subtitleError: err instanceof Error ? err.message : String(err),
        });
      }
    },

    generateVisualSubtitles: async () => {
      const s = get();
      if (!s.projectId || s.subtitleStatus === "running") return;
      const projectId = s.projectId;
      const spans = getClipSpans(s.clips, s.assets);
      if (spans.length === 0) {
        set({ subtitleStatus: "error", subtitleError: "Add a video to the timeline first." });
        return;
      }
      const duration = totalDuration(s.clips);
      set({ subtitleStatus: "running", subtitleError: null });
      try {
        const frames = await captureTimelineFrames(spans);
        if (frames.length === 0) throw new Error("Could not read any frames from the cut.");
        const res = await apiFetch("/api/cut/ai/visual-subtitles", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ frames, duration, locale: s.subtitles.locale ?? "en-US" }),
        });
        const body = await apiJson<{
          cues?: { start: number; end: number; text: string }[];
        }>(res);
        if (!res.ok || !Array.isArray(body.cues)) {
          throw new Error(body.error ?? "Captioning failed.");
        }
        if (get().projectId !== projectId) return; // switched projects mid-run
        const cues: SubtitleCue[] = body.cues.map((c) => ({
          id: uid(),
          start: c.start,
          end: c.end,
          text: c.text,
        }));
        push();
        set((cur) => ({
          subtitles: { ...cur.subtitles, cues, generatedAt: Date.now() },
          subtitleStatus: cues.length > 0 ? "ready" : "empty",
        }));
      } catch (err) {
        if (get().projectId !== projectId) return;
        set({
          subtitleStatus: "error",
          subtitleError: err instanceof Error ? err.message : String(err),
        });
      }
    },

    generateCaptions: async (style) => {
      const s = get();
      if (!s.projectId || s.subtitleStatus === "running") return;
      // Need cues first — transcribe if the cut hasn't been captioned yet.
      if (s.subtitles.cues.length === 0) {
        await s.generateSubtitles();
        if (get().subtitles.cues.length === 0) return; // no speech, or an error
      }
      const projectId = get().projectId;
      // Apply the look right away for instant feedback, then rewrite the text.
      set((cur) => ({
        subtitles: { ...cur.subtitles, style },
        subtitleStatus: "running",
        subtitleError: null,
      }));
      const cues = get().subtitles.cues;
      try {
        const res = await apiFetch("/api/cut/ai/captions", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            style,
            cues: cues.map((c) => ({ start: c.start, end: c.end, text: c.text })),
          }),
        });
        const body = await apiJson<{ texts?: string[] }>(res);
        if (get().projectId !== projectId) return;
        push();
        if (res.ok && Array.isArray(body.texts) && body.texts.length === cues.length) {
          // Key the rewrite to the cue ids it was generated from, so an edit
          // that reordered/split cues mid-request can't apply text by a stale
          // index onto the wrong cue.
          const byId = new Map(cues.map((c, i) => [c.id, body.texts![i]]));
          set((cur) => ({
            subtitles: {
              ...cur.subtitles,
              style,
              // Rewriting the text drops per-word timings (they no longer match),
              // but the cue's own start/end are untouched.
              cues: cur.subtitles.cues.map((c) => {
                const t = byId.get(c.id);
                return t && t !== c.text ? { ...c, text: t, words: undefined } : c;
              }),
            },
            subtitleStatus: "ready",
          }));
        } else {
          // The style still applied; leave the text as-is.
          set({ subtitleStatus: "ready" });
        }
      } catch (err) {
        if (get().projectId !== projectId) return;
        set({
          subtitleStatus: "ready",
          subtitleError: err instanceof Error ? err.message : String(err),
        });
      }
    },

    setSubtitlesView: (patch) =>
      set((s) => ({ subtitles: { ...s.subtitles, ...patch } })),

    setCueText: (id, text) => {
      const trimmed = text.replace(/\s+/g, " ").trim();
      const cue = get().subtitles.cues.find((c) => c.id === id);
      if (!cue || cue.text === trimmed) return;
      push();
      // A same-length edit (fixing a misheard word) keeps the real per-word
      // timings, just swapping the text; a word added/removed drops them and
      // falls back to proportional timing.
      const parts = trimmed.split(" ").filter(Boolean);
      const words =
        cue.words && cue.words.length === parts.length
          ? parts.map((w, i) => ({ ...cue.words![i], w }))
          : undefined;
      set((s) => ({
        subtitles: {
          ...s.subtitles,
          cues: trimmed
            ? s.subtitles.cues.map((c) => (c.id === id ? { ...c, text: trimmed, words } : c))
            : s.subtitles.cues.filter((c) => c.id !== id),
        },
      }));
    },

    splitCue: (id, charOffset) => {
      const s = get();
      const cue = s.subtitles.cues.find((c) => c.id === id);
      if (!cue) return;
      const before = cue.text.slice(0, charOffset).trim();
      const after = cue.text.slice(charOffset).trim();
      if (!before || !after) return;
      let leftEnd: number;
      let rightStart: number;
      let leftWords: SubtitleCue["words"];
      let rightWords: SubtitleCue["words"];
      if (cue.words && cue.words.length > 1) {
        // Word timings are intact: split on the word under the caret so both
        // halves keep real timestamps.
        let n = 0;
        let idx = cue.words.length - 1;
        for (let i = 0; i < cue.words.length; i++) {
          n += cue.words[i].w.length + 1;
          if (charOffset < n) {
            idx = Math.max(1, i + 1);
            break;
          }
        }
        leftWords = cue.words.slice(0, idx);
        rightWords = cue.words.slice(idx);
        if (rightWords.length === 0) return;
        leftEnd = leftWords[leftWords.length - 1].t1;
        rightStart = rightWords[0].t0;
      } else {
        const t = cue.start + (cue.end - cue.start) * (charOffset / Math.max(1, cue.text.length));
        leftEnd = rightStart = Math.round(t * 100) / 100;
      }
      push();
      const left: SubtitleCue = {
        ...cue,
        end: leftEnd,
        text: leftWords ? leftWords.map((w) => w.w).join(" ") : before,
        words: leftWords,
      };
      const right: SubtitleCue = {
        id: uid(),
        start: rightStart,
        end: cue.end,
        text: rightWords ? rightWords.map((w) => w.w).join(" ") : after,
        words: rightWords,
      };
      set((cur) => ({
        subtitles: {
          ...cur.subtitles,
          cues: cur.subtitles.cues.flatMap((c) => (c.id === id ? [left, right] : [c])),
        },
      }));
    },

    mergeCueIntoPrev: (id) => {
      const cues = get().subtitles.cues;
      const i = cues.findIndex((c) => c.id === id);
      if (i <= 0) return;
      push();
      const prev = cues[i - 1];
      const cue = cues[i];
      const merged: SubtitleCue = {
        ...prev,
        end: Math.max(prev.end, cue.end),
        text: `${prev.text} ${cue.text}`.replace(/\s+/g, " ").trim(),
        words: prev.words && cue.words ? [...prev.words, ...cue.words] : undefined,
      };
      set((s) => ({
        subtitles: {
          ...s.subtitles,
          cues: s.subtitles.cues.flatMap((c) =>
            c.id === prev.id ? [merged] : c.id === id ? [] : [c]
          ),
        },
      }));
    },

    deleteCue: (id) => {
      if (!get().subtitles.cues.some((c) => c.id === id)) return;
      push();
      set((s) => ({
        subtitles: { ...s.subtitles, cues: s.subtitles.cues.filter((c) => c.id !== id) },
      }));
    },

    updateCueTransient: (id, patch) =>
      set((s) => ({
        subtitles: {
          ...s.subtitles,
          cues: s.subtitles.cues.map((c) => (c.id === id ? { ...c, ...patch } : c)),
        },
      })),

    retimeCues: (entries) => {
      if (entries.length === 0) return;
      const byId = new Map(entries.map((e) => [e.id, e]));
      if (!get().subtitles.cues.some((c) => byId.has(c.id))) return;
      push();
      set((s) => ({
        subtitles: {
          ...s.subtitles,
          cues: s.subtitles.cues.map((c) => {
            const e = byId.get(c.id);
            if (!e) return c;
            const start = e.start;
            const end = Math.max(start + 0.05, e.end);
            return { ...c, start, end, words: spreadWordsEvenly(c.text, start, end) };
          }),
        },
      }));
    },

    sortCues: () =>
      set((s) => ({
        subtitles: {
          ...s.subtitles,
          cues: [...s.subtitles.cues].sort((a, b) => a.start - b.start),
        },
      })),
    setPxPerSec: (v) => {
      const pxPerSec = Math.max(12, Math.min(800, v));
      set({ pxPerSec });
      const id = get().projectId;
      if (id) saveUiState(id, { pxPerSec: Math.round(pxPerSec * 100) / 100 });
    },
    setTimelineH: (h) => {
      const timelineH = Math.round(Math.max(TIMELINE_H_MIN, Math.min(TIMELINE_H_MAX, h)));
      set({ timelineH });
      const id = get().projectId;
      if (id) saveUiState(id, { timelineH });
    },
    setExportOpen: (v) => set({ exportOpen: v }),
    setDropActive: (v) => set({ dropActive: v }),
    setAiOpen: (v) => {
      set({ aiOpen: v });
      try {
        localStorage.setItem("cut-ai-open", v ? "1" : "0");
      } catch {
        // View preference only.
      }
    },

    copySelection: () => {
      const s = get();
      const sels = s.multiSelection.length ? s.multiSelection : s.selection ? [s.selection] : [];
      const items: ClipboardItem[] = [];
      for (const sel of sels) {
        if (sel?.kind === "clip") {
          const c = s.clips.find((x) => x.id === sel.id);
          if (c) items.push({ kind: "clip", item: { ...c } });
        } else if (sel?.kind === "audio") {
          const a = s.audioClips.find((x) => x.id === sel.id);
          if (a) items.push({ kind: "audio", item: { ...a } });
        } else if (sel?.kind === "overlayClip") {
          const c = s.overlayClips.find((x) => x.id === sel.id);
          if (c) items.push({ kind: "overlayClip", item: { ...c } });
        } else if (sel?.kind === "text") {
          const o = s.overlays.find((x) => x.id === sel.id);
          if (o) items.push({ kind: "text", item: { ...o } });
        }
      }
      if (items.length === 0) return false;
      clipboard = items;
      return true;
    },

    paste: () => {
      if (clipboard.length === 0) return false;
      const s = get();
      // Every copied clip's media must still exist in this project.
      if (
        clipboard.some(
          (cb) => cb.kind !== "text" && !s.assets.some((a) => a.id === cb.item.assetId)
        )
      )
        return false;
      push();
      const t = Math.max(0, s.currentTime);
      // Video clips insert together, after the clip under the playhead.
      const spans = getClipSpans(s.clips, s.assets);
      let insertAt = s.clips.length;
      for (let i = 0; i < spans.length; i++) {
        if (t < spans[i].start + spans[i].len) {
          insertAt = i + 1;
          break;
        }
      }
      const newSel: Selection[] = [];
      set((cur) => {
        let clips = cur.clips;
        let audioClips = cur.audioClips;
        let overlayClips = cur.overlayClips;
        let overlays = cur.overlays;
        let at = insertAt;
        // Free-positioned items aim for the playhead but respect what already
        // sits on their lane: an occupied spot slides the paste right to the
        // next gap that fits. Earlier items of this same paste count too.
        for (const cb of clipboard) {
          if (cb.kind === "clip") {
            const clip: VideoClip = { ...cb.item, id: uid() };
            clips = [...clips.slice(0, at), clip, ...clips.slice(at)];
            at++;
            newSel.push({ kind: "clip", id: clip.id });
          } else if (cb.kind === "audio") {
            const taken = audioClips.map((a) => ({ start: a.start, end: a.start + clipLen(a) }));
            const item: AudioClip = { ...cb.item, id: uid(), start: nextFreeStart(taken, t, clipLen(cb.item)) };
            audioClips = [...audioClips, item];
            newSel.push({ kind: "audio", id: item.id });
          } else if (cb.kind === "overlayClip") {
            const taken = overlayClips
              .filter((c) => c.track === cb.item.track)
              .map((c) => ({ start: c.start, end: c.start + clipLen(c) }));
            const item: OverlayClip = { ...cb.item, id: uid(), start: nextFreeStart(taken, t, clipLen(cb.item)) };
            overlayClips = [...overlayClips, item];
            newSel.push({ kind: "overlayClip", id: item.id });
          } else {
            const len = Math.max(0.2, cb.item.end - cb.item.start);
            const taken = overlays
              .filter((o) => (o.lane ?? 0) === (cb.item.lane ?? 0))
              .map((o) => ({ start: o.start, end: o.end }));
            const start = nextFreeStart(taken, t, len);
            const item: TextOverlay = { ...cb.item, id: uid(), start, end: start + len };
            overlays = [...overlays, item];
            newSel.push({ kind: "text", id: item.id });
          }
        }
        return { clips, audioClips, overlayClips, overlays, selection: newSel[newSel.length - 1] ?? null, multiSelection: newSel };
      });
      return true;
    },

    undo: () => {
      flush(); // commit any uncommitted edit before stepping back
      const prev = history.pop();
      if (!prev) return;
      future.push(snapshot());
      set({ ...prev, selection: null, multiSelection: [] });
    },

    redo: () => {
      flush();
      const next = future.pop();
      if (!next) return;
      history.push(snapshot());
      if (history.length > HISTORY_CAP) history.shift();
      set({ ...next, selection: null, multiSelection: [] });
    },
  };
});

// Track real edits to the persistable doc so a deferred checkpoint (see push)
// knows whether an edit actually happened between capture and commit.
useEditor.subscribe((s, prev) => {
  if (
    s.clips !== prev.clips ||
    s.audioClips !== prev.audioClips ||
    s.overlayClips !== prev.overlayClips ||
    s.overlays !== prev.overlays ||
    s.subtitles !== prev.subtitles
  )
    docSeq++;
});

/** The persistable slice of the editor state, for autosave. */
export function serializeDoc(s: {
  projectName: string;
  assets: MediaAsset[];
  clips: VideoClip[];
  audioClips: AudioClip[];
  overlayClips: OverlayClip[];
  overlays: TextOverlay[];
  aspect: Aspect;
  fadeIn: number;
  fadeOut: number;
  publish: { caption: string; tags: string; soundTitle: string; handle: string };
  notes: { text: string; publishedAt: string; links: string[] };
  subtitles: SubtitlesBlock;
}): Partial<ProjectDoc> {
  const assets: StoredAsset[] = s.assets.map(
    ({ id, fileName, name, type, duration, width, height, origin }) => ({
      id,
      fileName,
      name,
      type,
      duration,
      ...(width !== undefined ? { width } : {}),
      ...(height !== undefined ? { height } : {}),
      ...(origin !== undefined ? { origin } : {}),
    })
  );
  return {
    name: s.projectName,
    assets,
    clips: s.clips,
    audioClips: s.audioClips,
    overlayClips: s.overlayClips,
    overlays: s.overlays,
    aspect: s.aspect,
    fadeIn: s.fadeIn,
    fadeOut: s.fadeOut,
    subtitles: s.subtitles,
    publish: { ...s.publish },
    notes: { ...s.notes, links: [...s.notes.links] },
  };
}

/** Effective playback rate of a video clip (>0, default 1). */
export function clipSpeed(c: VideoClip) {
  const s = c.speed ?? 1;
  return s > 0 ? s : 1;
}

export function clipLen(c: VideoClip | AudioClip) {
  const src = c.out - c.in;
  // Video clips play their source at `speed`, so the timeline footprint is
  // shorter/longer than the source. Audio clips have no speed.
  const eff = "speed" in c && c.speed && c.speed > 0 ? src / c.speed : src;
  return Math.max(MIN_LEN, eff);
}

/** Overlap (timeline seconds) between a clip and its successor, clamped so it
 * can never swallow either clip whole. 0 when there is no next clip, no
 * transition set, or the style is an edge style (those ramp one clip's edge
 * around a hard cut instead of overlapping). */
export function transitionOverlap(a: VideoClip, b: VideoClip | undefined): number {
  const d = a.transition ?? 0;
  if (!b || d <= 0) return 0;
  if (!isCrossStyle(a.transitionStyle ?? "crossfade")) return 0;
  return Math.min(d, clipLen(a) * 0.9, clipLen(b) * 0.9);
}

export function getClipSpans(
  clips: VideoClip[],
  assets: MediaAsset[]
): ClipSpan[] {
  // Map lookup, not a per-clip assets.find — this runs every playback frame.
  const byId = new Map(assets.map((a) => [a.id, a]));
  // Lay out only clips whose media is present; a transition joins adjacent
  // present clips, so resolve the list first.
  const present = clips
    .map((clip) => ({ clip, asset: byId.get(clip.assetId) }))
    .filter((x): x is { clip: VideoClip; asset: MediaAsset } => !!x.asset);
  const spans: ClipSpan[] = [];
  let t = 0;
  for (let i = 0; i < present.length; i++) {
    const { clip, asset } = present[i];
    const len = clipLen(clip);
    const overlap = transitionOverlap(clip, present[i + 1]?.clip);
    spans.push({ clip, asset, start: t, len, transitionOut: overlap });
    t += len - overlap; // the next clip starts early by the dissolve length
  }
  return spans;
}

export function totalDuration(clips: VideoClip[]) {
  let t = 0;
  for (let i = 0; i < clips.length; i++) {
    t += clipLen(clips[i]) - transitionOverlap(clips[i], clips[i + 1]);
  }
  return Math.max(0, t);
}

/** The playable length of the whole project: the base track plus anything that
 * runs past it on an upper/lower video track or the soundtrack. Drives the
 * timeline extent, the seek clamp, and export length so content beyond the base
 * is reachable. */
export function projectDuration(s: {
  clips: VideoClip[];
  overlayClips: OverlayClip[];
  audioClips: AudioClip[];
}): number {
  let end = totalDuration(s.clips);
  for (const c of s.overlayClips) {
    const sp = c.speed && c.speed > 0 ? c.speed : 1;
    end = Math.max(end, c.start + Math.max(0.1, (c.out - c.in) / sp));
  }
  for (const a of s.audioClips) end = Math.max(end, a.start + clipLen(a));
  return Math.max(0, end);
}

/**
 * Build the annotation shifter for a video-track edit (clip delete, asset
 * removal). Titles and cues are pinned to timeline time, so when clips go the
 * track re-lays-out and everything downstream must move with the content it
 * sat over. Comparing the real old/new overlap-aware layouts — rather than
 * assuming each removed clip vacates its full length — keeps annotations
 * aligned even across cross-dissolves. An annotation over surviving content
 * moves by that clip's shift; one over a removed gap collapses to the join;
 * one past everything shifts by the whole-timeline length change.
 */
/** Spread a cue's words across [start, end], each word's slice proportional to
 * its length. Used when re-timing captions to a generated voiceover, which
 * carries no per-word timestamps of its own. */
function spreadWordsEvenly(
  text: string,
  start: number,
  end: number,
): { t0: number; t1: number; w: string }[] | undefined {
  const parts = text.split(/\s+/).filter(Boolean);
  if (parts.length === 0) return undefined;
  const lengths = parts.map((w) => Math.max(1, w.length));
  const total = lengths.reduce((a, b) => a + b, 0);
  const span = Math.max(0, end - start);
  let acc = 0;
  return parts.map((w, i) => {
    const t0 = start + (acc / total) * span;
    acc += lengths[i];
    const t1 = start + (acc / total) * span;
    return { t0, t1, w };
  });
}

function makeRipple(oldClips: VideoClip[], newClips: VideoClip[], assets: MediaAsset[]) {
  const newStart = new Map(getClipSpans(newClips, assets).map((sp) => [sp.clip.id, sp.start]));
  const totalDelta = totalDuration(newClips) - totalDuration(oldClips);
  const survivors = getClipSpans(oldClips, assets)
    .filter((sp) => newStart.has(sp.clip.id))
    .map((sp) => ({
      oldStart: sp.start,
      oldEnd: sp.start + sp.len,
      newStart: newStart.get(sp.clip.id)!,
    }));
  const shiftFor = (a: number) => {
    for (const s of survivors) {
      if (a <= s.oldEnd + 1e-6)
        return a >= s.oldStart - 1e-6 ? s.newStart - s.oldStart : s.newStart - a;
    }
    return totalDelta;
  };
  return <T extends { start: number; end: number }>(item: T): T => {
    const d = shiftFor(item.start);
    return d ? { ...item, start: Math.max(0, item.start + d), end: Math.max(0, item.end + d) } : item;
  };
}

export const useTotalDuration = () => useEditor((s) => totalDuration(s.clips));
