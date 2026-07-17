"use client";

import { create } from "zustand";
import type {
  Aspect,
  AudioClip,
  ClipSpan,
  LibraryTemplate,
  MediaAsset,
  ProjectDoc,
  Selection,
  StoredAsset,
  SubtitleCue,
  SubtitlesBlock,
  SubtitleTrackMeta,
  TemplateAudio,
  TemplateLayer,
  TemplateMedia,
  TemplateSaveInput,
  TextOverlay,
  TransitionStyle,
  VideoClip,
} from "./types";
import type { VideoProject } from "./genvideo/types";
import { fillSlot } from "./genvideo/fillSlot";
import { apiFetch, apiJson } from "./api";
import { trackLocale } from "./subtitles";
import { emptySubtitles, IMAGE_CLIP_SECONDS, isCrossStyle, MAX_SUBTITLE_LANES, mediaUrl, SPEED_FLOOR, SPEED_MIN, TRANSITION_MAX } from "./types";
import { readTextStyle } from "./textStyle";
import { loadUiState, saveUiState } from "./uiState";
import { captureTimelineFrames } from "./visualFrames";

const uid = () => crypto.randomUUID().slice(0, 8);

const MIN_LEN = 0.1;

/** Where a video clip lands when dropped: an existing track or a brand-new
 * track inserted at z-level `level`. Track numbers are signed: track 0 is the
 * base row, positive tracks sit above it (higher = closer to the top), negative
 * tracks sit below it (more negative = further behind). Inserting shifts the
 * tracks past `level` (up for positive, down for negative) to open the slot. */
export type VideoTrackPlacement =
  | { kind: "track"; track: number }
  | { kind: "insert"; level: number };

/** The base row (track 0) clips — the master sequence that carries transitions
 * and drives playback. */
export const baseClips = (clips: VideoClip[]) => clips.filter((c) => c.track === 0);
/** Every video clip not on the base row (track 0) — the composited layers. */
export const overlayLayers = (clips: VideoClip[]) => clips.filter((c) => c.track !== 0);

/** Open a slot at a non-zero `level`, moving other clips out of the way: above
 * track 0 (level > 0) shifts tracks at/above it up; below track 0 (level < 0)
 * shifts tracks at/below it down. Track-0 clips never match a non-zero level, so
 * this is safe to run over the whole clip list. `exclude` is the clip being
 * placed (left untouched). */
function openInsertSlot(clips: VideoClip[], level: number, exclude?: string): VideoClip[] {
  return level > 0
    ? clips.map((c) => (c.id !== exclude && c.track >= level ? { ...c, track: c.track + 1 } : c))
    : clips.map((c) => (c.id !== exclude && c.track <= level ? { ...c, track: c.track - 1 } : c));
}
const shiftTracksUp = (clips: VideoClip[], place: VideoTrackPlacement): VideoClip[] =>
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
  overlays: TextOverlay[];
  subtitles: SubtitlesBlock;
}

export type SubtitleStatus = "idle" | "running" | "ready" | "empty" | "error";

export type SaveState = "saved" | "dirty" | "saving" | "error";

export interface EditorState {
  projectId: string | null;
  projectName: string;
  loaded: boolean;
  loadError: string | null;
  saveState: SaveState;

  assets: MediaAsset[];
  /** Every video clip, on any track. Track 0 is the base row (the master
   * sequence); other tracks composite around it (positive above, negative
   * behind). A clip's `track` field is the only thing that places it. */
  clips: VideoClip[];
  audioClips: AudioClip[];
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
  /** Epoch ms when the running transcription/translation started — the panel
   * shows a ticking elapsed beside its spinner. */
  subtitleStartedAt: number | null;
  exportOpen: boolean;
  /** OS file drag in flight: "media" when it carries video/audio/image (so the
   * timeline is a valid target), "other" for text-only drags, null when idle. */
  dropActive: "media" | "other" | null;
  /** Whether the AI assistant panel is open (remembered across sessions). */
  aiOpen: boolean;
  /** In-progress or finished brief-to-video run; persisted on ProjectDoc.genvideo
   * and driven by the genScene store. Absent when no scene was generated. */
  genvideo?: VideoProject;

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
  /** Add a video clip from an asset onto video track 0 — at `start` (sliding
   * to the track's next free slot), or appended at the end when omitted. */
  addClipFromAsset: (assetId: string, start?: number) => void;
  /** Add a soundtrack clip from an audio asset at `start` (default: the
   * playhead). `opts.duck` marks it a voiceover that lowers everything else
   * to that gain while it plays; `opts.lane` picks the audio track it lands
   * on (default: the first one). */
  addAudioFromAsset: (assetId: string, start?: number, opts?: { duck?: number; lane?: number }) => void;
  /** Set (or clear) the persisted brief-to-video run. Replaces the object by
   * reference so autosave detects the change. */
  setGenvideo: (project: VideoProject | undefined) => void;
  /** Brief-to-video placement: place a generated clip so it fills exactly
   * [startSec, endSec) on track 0 — exact start (no slide), muted, time-stretched
   * or trimmed to the slot — and return its id. Leaves selection untouched (the
   * run is a background process). */
  placeGenClip: (assetId: string, startSec: number, endSec: number, opts?: { srcInSec?: number }) => string | null;
  /** Brief-to-video placement: place a generated audio clip at startSec spanning
   * up to durSec on the soundtrack (duck/lane optional), returning its id. */
  placeGenAudio: (assetId: string, startSec: number, durSec: number, opts?: { duck?: number; lane?: number }) => string | null;
  /** Remove a video clip by id (a background gen swap; leaves its slot empty). */
  removeClipById: (id: string) => void;
  /** Remove a soundtrack clip by id (background gen swap, idempotent placement). */
  removeAudioById: (id: string) => void;
  /** Re-mark a resumed run's already-placed clips as render-owned. The gen sets
   * reset on load, so hydrate re-registers the persisted plan's clip ids to keep
   * undo/redo off them while the run finishes. */
  adoptGenClips: (clipIds: string[], audioIds: string[]) => void;
  /** Hand a finished run's clips over to the user's undo domain: splice them
   * into every existing history snapshot (which excluded them while the run
   * owned them) and clear the gen sets, so post-run edits to generated clips
   * undo like any other edit. */
  releaseGenClips: () => void;
  addOverlay: () => void;
  updateClip: (id: string, patch: Partial<VideoClip>) => void;
  /** Set a clip's playback rate (0.25–4). A longer footprint pushes the
   * following clips right by the overflow; a shorter one opens a gap. */
  setClipSpeed: (id: string, speed: number) => void;
  /** Set a clip's source trim points with the same run rules as a speed
   * resize: a longer footprint pushes the following clips right, a shorter
   * one opens a gap, and a live dissolve keeps its overlap. */
  setClipTrim: (id: string, nextIn: number, nextOut: number) => void;
  /** Set the transition into the next clip (seconds; 0 clears it), optionally
   * changing its style; omitting the style keeps the clip's current one. */
  setClipTransition: (id: string, seconds: number, style?: TransitionStyle) => void;
  updateAudio: (id: string, patch: Partial<AudioClip>) => void;
  updateOverlay: (id: string, patch: Partial<TextOverlay>) => void;
  /** Live-drag updates that should not create undo entries. */
  updateOverlayTransient: (id: string, patch: Partial<TextOverlay>) => void;
  /** Patch several items in one commit — the lane coordinator's gestures part
   * and push whole lanes at a time (one bulk patcher per lane-track kind). */
  updateOverlaysTransient: (patches: { id: string; patch: Partial<TextOverlay> }[]) => void;
  updateAudiosTransient: (patches: { id: string; patch: Partial<AudioClip> }[]) => void;
  /** Bulk-patch layer (non-base-track) clips in one commit — the lane
   * coordinator parts and pushes a whole track at a time. */
  updateOverlayClipsTransient: (patches: { id: string; patch: Partial<VideoClip> }[]) => void;
  updateCuesTransient: (patches: { id: string; patch: Partial<SubtitleCue> }[]) => void;
  updateClipsTransient: (patches: { id: string; patch: Partial<VideoClip> }[]) => void;
  updateClipTransient: (id: string, patch: Partial<VideoClip>) => void;
  updateAudioTransient: (id: string, patch: Partial<AudioClip>) => void;
  /** Keep the clips array sorted by start (consumers read `clips[0]` as the
   * timeline's first clip). Called after a lane-coordinator move commits. */
  sortClips: () => void;
  /** Reorder video track 0 by index (the AI reorder op): the clip lifts out
   * (leaving a gap) and a slot opens at the target index — clips from the
   * landing point shift right; nothing else moves. */
  moveClip: (id: string, toIndex: number) => void;
  /** Add a video asset to the timeline at a placement: an existing track or a
   * freshly inserted one. Used by media / library drops. */
  addVideoFromAsset: (assetId: string, place: VideoTrackPlacement, start: number) => void;
  /** Move an existing clip to a placement, preserving its trim/region/speed.
   * Inserting a track renumbers the ones above it; dropping onto track 0 lands
   * free-positioned at the drop time. Owns its own history. */
  dropVideoClip: (id: string, place: VideoTrackPlacement, start: number) => void;
  updateOverlayClip: (id: string, patch: Partial<VideoClip>) => void;
  updateOverlayClipTransient: (id: string, patch: Partial<VideoClip>) => void;
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
  /** Transcribe one clip's own audio (even when muted) and merge its cues into
   * the subtitles; cues elsewhere on the timeline stay put. Throws a
   * user-facing error on failure. */
  generateClipSubtitles: (clipId: string) => Promise<void>;
  /** Caption the cut from its picture alone (no audio needed): sample frames
   * along the timeline and have the AI write timed narration cues. */
  generateVisualSubtitles: () => Promise<void>;
  /** Transcribe (if needed) then rewrite the cues into social captions in the
   * given style, one-to-one so cue timings are preserved. */
  generateCaptions: (style: "clean" | "hook" | "punchy") => Promise<void>;
  /** Fill the active track by translating another track's cues into the active
   * track's language. Timings copy over; word timings don't survive
   * translation, so the new cues carry none. */
  translateSubtitleTrack: (fromLane: number) => Promise<void>;
  setSubtitlesView: (patch: Partial<Pick<SubtitlesBlock, "showOnVideo" | "showOnTimeline" | "locale" | "style" | "x" | "y" | "wordHighlight" | "accentMode" | "accentColor">>) => void;
  /** The subtitle track (row) the panel edits and generation writes to. */
  subtitleLane: number;
  setSubtitleLane: (lane: number) => void;
  /** Add a subtitle track — one language each, capped at MAX_SUBTITLE_LANES —
   * and make it the active one. */
  addSubtitleTrack: (locale?: string) => void;
  /** Remove a subtitle track: drops its cues and shifts higher tracks down. */
  removeSubtitleTrack: (lane: number) => void;
  /** Patch one track's settings (locale, dragged caption anchor). */
  setSubtitleTrackMeta: (lane: number, patch: Partial<SubtitleTrackMeta>) => void;
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
  seek: (t: number) => void;
  setPlaying: (p: boolean) => void;
  setPxPerSec: (v: number) => void;
  setTimelineH: (h: number) => void;
  setExportOpen: (v: boolean) => void;
  setDropActive: (v: "media" | "other" | null) => void;
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

/** Ids of clips a background generation run placed. Those clips are the
 * orchestrator's to manage — it swaps them idempotently and holds each shot's
 * timeline id — so the user's undo/redo must neither remove nor resurrect them.
 * They are dropped from every history snapshot and re-attached live on restore,
 * so stepping through history can't open a black gap under a running render or
 * bring back a shot the run already replaced. Transient: not persisted and
 * cleared on load, so a reopened project treats them as ordinary clips. */
const genClipIds = new Set<string>();
const genAudioIds = new Set<string>();

/** Timeline clipboard (⌘C/⌘V) — survives across projects in one session. One
 * entry per copied item so a multi-selection round-trips. */
type ClipboardItem =
  | { kind: "clip"; item: VideoClip }
  | { kind: "audio"; item: AudioClip }
  | { kind: "text"; item: TextOverlay };
let clipboard: ClipboardItem[] = [];

/** Bumped whenever subtitle lanes renumber (a track removal). Async work that
 * captured a lane index checks it before landing, so a result can't write to
 * what is now a different language's track. */
let laneEpoch = 0;

/** Resize a clip's footprint to `newLen` (a trim or speed change), keeping its
 * own track sound: a live dissolve into the next clip stays a dissolve (the
 * run follows the resize so the pair keeps its overlap); otherwise a longer
 * footprint pushes the run right by the overflow and a shorter one just opens
 * a gap. Everything is scoped to the clip's track — resizing a base clip never
 * drags the composited layers (or vice versa), so each track's annotations
 * keep the timing they were placed at. One undo step. */
function resizeClipFootprint(clip: VideoClip, patch: Partial<VideoClip>, newLen: number) {
  useEditor.getState().pushHistory();
  useEditor.getState().updateClipTransient(clip.id, patch);
  const next = useEditor
    .getState()
    .clips.filter((c) => c.id !== clip.id && c.track === clip.track && c.start >= clip.start)
    .reduce<VideoClip | null>((m, c) => (!m || c.start < m.start ? c : m), null);
  const nextStart = next?.start ?? Infinity;
  const keep = next
    ? Math.min(
        transitionOverlap(clip, next),
        Math.max(0, clip.start + clipLen(clip) - nextStart),
        newLen * 0.9
      )
    : 0;
  const delta =
    keep > 1e-6
      ? clip.start + newLen - keep - nextStart
      : Math.max(0, clip.start + newLen - nextStart);
  if (Math.abs(delta) > 1e-6) {
    useEditor.setState((st) => ({
      clips: st.clips
        .map((c) =>
          c.id !== clip.id && c.track === clip.track && c.start >= clip.start
            ? { ...c, start: Math.max(0, c.start + delta) }
            : c
        )
        .sort((a, b) => a.start - b.start),
    }));
  }
}
const staleLaneError = {
  subtitleStatus: "error" as const,
  subtitleError: "Subtitle tracks changed while working — run it again.",
};

/** Earliest start at/after `t` where a `len`-long item fits between the
 * occupied `spans` of one lane: each blocker slides the candidate right to its
 * end until a big-enough gap opens. The one placement-collision primitive for
 * every lane track (add, paste, drop). */
export function nextFreeStart(spans: { start: number; end: number }[], t: number, len: number): number {
  const sorted = [...spans].sort((a, b) => a.start - b.start);
  let at = t;
  for (const sp of sorted) {
    if (sp.end <= at + 1e-3) continue;
    if (sp.start >= at + len - 1e-3) break;
    at = sp.end;
  }
  return at;
}

/** The timeline footprints (start/end) of a set of clips, for the `nextFreeStart`
 * collision test. Every placement path — add, drop, paste — occupies the same
 * shape, so they share this instead of re-deriving `start + clipLen` inline. */
export function footprints(items: (VideoClip | AudioClip)[]): { start: number; end: number }[] {
  return items.map((c) => ({ start: c.start, end: c.start + clipLen(c) }));
}

/** POST a transcribe spec and poll the job to completion. Returns the cues, or
 * null when the user switches projects mid-run. Throws user-facing errors.
 * Shared with the brief-to-video transcribe adapter. */
export async function runTranscription(projectId: string, spec: object): Promise<SubtitleCue[] | null> {
  const res = await apiFetch(`/api/cut/projects/${projectId}/transcribe`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(spec),
  });
  const body = await apiJson<{ id?: string }>(res);
  if (!res.ok || !body.id) throw new Error(body.error ?? "Transcription failed to start.");
  for (;;) {
    await new Promise((r) => setTimeout(r, 600));
    if (useEditor.getState().projectId !== projectId) return null;
    const st = await apiFetch(`/api/cut/projects/${projectId}/transcribe?job=${body.id}`);
    if (!st.ok) throw new Error("The transcription job was lost — try again.");
    const status = (await st.json()) as { status: string; error?: string; cues?: SubtitleCue[] };
    if (status.status === "error") throw new Error(status.error ?? "Transcription failed.");
    if (status.status === "done") {
      return useEditor.getState().projectId === projectId ? (status.cues ?? []) : null;
    }
  }
}

export const useEditor = create<EditorState>((set, get) => {
  const snapshot = (): DocSnapshot => {
    const { clips, audioClips, overlays, subtitles } = get();
    return {
      // Render-owned clips are excluded — history captures the user's timeline,
      // not the background run's placements (restoreDoc re-attaches the live ones).
      clips: clips.filter((c) => !genClipIds.has(c.id)).map((c) => ({ ...c })),
      audioClips: audioClips.filter((c) => !genAudioIds.has(c.id)).map((c) => ({ ...c })),
      overlays: overlays.map((o) => ({ ...o })),
      subtitles: {
        ...subtitles,
        cues: subtitles.cues.map((c) => ({ ...c, words: c.words?.map((w) => ({ ...w })) })),
      },
    };
  };

  /** Apply a history snapshot, re-attaching the render-owned clips it omitted so
   * an undo/redo never disturbs a background run's placements. The live gen
   * clips are read at restore time, so the set is always current. */
  const restoreDoc = (snap: DocSnapshot) => {
    const { clips, audioClips } = get();
    const genClips = clips.filter((c) => genClipIds.has(c.id));
    const genAudio = audioClips.filter((c) => genAudioIds.has(c.id));
    set({
      ...snap,
      clips: [...snap.clips, ...genClips].sort((a, b) => a.start - b.start),
      audioClips: [...snap.audioClips, ...genAudio],
      selection: null,
      multiSelection: [],
    });
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

  /** Remove one gen-swap placement (video or audio) by id: the clip, its
   * gen-set entry, and any selection pointing at it. No push() — the
   * orchestrator's swaps stay off the undo stack. */
  const removeGenPlacement = (id: string, kind: "clip" | "audio") => {
    const exists =
      kind === "clip"
        ? get().clips.some((c) => c.id === id)
        : get().audioClips.some((c) => c.id === id);
    if (!exists) return;
    (kind === "clip" ? genClipIds : genAudioIds).delete(id);
    set((s) => {
      const keep = (sel: Selection) => !(!!sel && sel.kind === kind && sel.id === id);
      const multiSelection = s.multiSelection.filter(keep);
      return {
        ...(kind === "clip"
          ? { clips: s.clips.filter((c) => c.id !== id) }
          : { audioClips: s.audioClips.filter((c) => c.id !== id) }),
        multiSelection,
        selection: keep(s.selection) ? s.selection : multiSelection[multiSelection.length - 1] ?? null,
      };
    });
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
    subtitleLane: 0,
    subtitleStatus: "idle",
    subtitleError: null,
    subtitleStartedAt: null,
    exportOpen: false,
    dropActive: null,
    aiOpen: typeof window !== "undefined" && localStorage.getItem("cut-ai-open") === "1",
    genvideo: undefined,

    loadProject: async (id) => {
      // A background scene run may still be writing this project's doc — wait
      // out its queued writes so the load never reads a half-written doc (and
      // never later autosaves over a placement it didn't see). Lazy import:
      // docWriter reads store helpers, so a static import would be a cycle.
      await import("./genvideo/docWriter").then((m) => m.docWriterIdle(id)).catch(() => {});
      history.length = 0;
      future.length = 0;
      pending = null;
      // A fresh project owns no live run — any prior run's render-owned ids are
      // stale, and the loaded clips are ordinary, fully-undoable content.
      genClipIds.clear();
      genAudioIds.clear();
      set({
        projectId: id,
        loaded: false,
        loadError: null,
        saveState: "saved",
        assets: [],
        clips: [],
        audioClips: [],
        overlays: [],
        aspect: "9:16",
        fadeIn: 0,
        fadeOut: 0,
        selection: null,
        multiSelection: [],
        currentTime: 0,
        playing: false,
        subtitles: emptySubtitles(),
        subtitleLane: 0,
        subtitleStatus: "idle",
        subtitleError: null,
        exportOpen: false,
        genvideo: undefined,
      });
      try {
        const [res, ui] = await Promise.all([apiFetch(`/api/cut/projects/${id}`), loadUiState(id)]);
        if (!res.ok) throw new Error("This project no longer exists.");
        const doc = (await res.json()) as ProjectDoc;
        const assets: MediaAsset[] = doc.assets.map((a) => ({
          ...a,
          url: mediaUrl(id, a.fileName),
        }));
        // Older docs stored video track 0 packed (array order implied the
        // position); bake explicit starts in once so every clip is free-placed.
        const legacy = (doc.clips as LegacyClip[]).some((c) => typeof c.start !== "number");
        const base = (legacy ? packStarts(doc.clips as LegacyClip[]) : doc.clips).map((c) => ({
          ...c,
          track: c.track ?? 0,
        }));
        // Older docs kept non-base tracks in a separate `overlayClips` array;
        // fold them into the one clip list (each already carries its `track`).
        // Entries whose id already sits in `clips` are the same clip persisted
        // twice by a version-skewed save (an older engine keeps overlayClips
        // after a merged client writes the folded list) — keep the folded copy.
        // Entries with track 0 were unreachable dead data under the split shape
        // (never rendered, never played); promoting them would insert them into
        // the master sequence, so they stay dropped.
        const seen = new Set(base.map((c) => c.id));
        const legacyLayers = (doc.overlayClips ?? []).filter(
          (c) => c.track !== 0 && !seen.has(c.id)
        );
        const merged = [...base, ...legacyLayers];
        set({
          projectName: doc.name,
          assets,
          clips: merged,
          audioClips: doc.audioClips,
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
          genvideo: doc.genvideo ?? undefined,
          loaded: true,
        });
      } catch (err) {
        set({ loadError: err instanceof Error ? err.message : String(err) });
      }
    },

    setProjectName: (name) => set({ projectName: name }),
    setSaveState: (s) => set({ saveState: s }),

    // Clone so each persist yields a fresh top-level reference: the orchestrator
    // mutates one project object in place, and autosave detects a genvideo change
    // by identity — without the clone every save after the first looks unchanged
    // and the plan is never written back.
    setGenvideo: (project) => set({ genvideo: project ? { ...project } : undefined }),

    placeGenClip: (assetId, startSec, endSec, opts) => {
      const asset = get().assets.find((a) => a.id === assetId);
      if (!asset || (asset.type !== "video" && asset.type !== "image")) return null;
      const slot = Math.max(MIN_LEN, endSec - startSec);
      // The reviewer's chosen window: start the source there, clamped so the
      // slot still fits inside the file.
      const srcIn =
        asset.type === "video"
          ? Math.min(Math.max(0, opts?.srcInSec ?? 0), Math.max(0, asset.duration - slot))
          : 0;
      // Fill the slot exactly so the track never opens a gap between shots —
      // fillSlot mirrors the plan's frame-coverage invariant at this boundary.
      const { out, speed } = fillSlot(
        asset.type,
        Math.max(MIN_LEN, asset.duration - srcIn),
        slot,
        SPEED_MIN
      );
      const clip: VideoClip = {
        id: uid(),
        assetId,
        track: 0,
        start: Math.max(0, startSec),
        in: srcIn,
        out: srcIn + out,
        // Muted: generated shots ride under the narration spine, so the clip's
        // own audio (Veo synthesizes some) must never compete with the voice.
        muted: true,
        ...(speed !== undefined ? { speed } : {}),
      };
      // Render-owned: no push(), and tracked so history snapshots exclude it —
      // the orchestrator manages this clip (it swaps clips idempotently), so a
      // mid-render Cmd+Z must not pull a shot out from under the run.
      genClipIds.add(clip.id);
      set((s) => ({ clips: [...s.clips, clip].sort((a, b) => a.start - b.start) }));
      return clip.id;
    },

    placeGenAudio: (assetId, startSec, durSec, opts) => {
      const asset = get().assets.find((a) => a.id === assetId);
      if (!asset || asset.type !== "audio") return null;
      const out = Math.min(asset.duration, Math.max(MIN_LEN, durSec));
      const lane = opts?.lane ?? 0;
      const clip: AudioClip = {
        id: uid(),
        assetId,
        start: Math.max(0, startSec),
        in: 0,
        out,
        volume: 1,
        ...(opts?.duck !== undefined && opts.duck < 1 ? { duck: Math.max(0, opts.duck) } : {}),
        ...(lane > 0 ? { lane } : {}),
      };
      // Render-owned: no push(), tracked so history snapshots exclude it.
      genAudioIds.add(clip.id);
      set((s) => ({ audioClips: [...s.audioClips, clip] }));
      return clip.id;
    },

    // Shared body of the two gen-swap removals: drop the clip, its gen-set
    // entry, and any selection pointing at it — with no push(), because the
    // orchestrator's swaps stay off the undo stack.
    removeClipById: (id) => removeGenPlacement(id, "clip"),

    adoptGenClips: (clipIds, audioIds) => {
      for (const id of clipIds) genClipIds.add(id);
      for (const id of audioIds) genAudioIds.add(id);
      // The invariant is exact: no history snapshot holds a gen-owned clip.
      // Re-adopting released clips (a regeneration after done) scrubs them back
      // out of existing snapshots, so the eventual release grafts exactly one
      // copy and an undo never restores a clip the run has since swapped.
      const scrub = (snap: DocSnapshot) => {
        snap.clips = snap.clips.filter((c) => !genClipIds.has(c.id));
        snap.audioClips = snap.audioClips.filter((c) => !genAudioIds.has(c.id));
      };
      for (const snap of history) scrub(snap);
      for (const snap of future) scrub(snap);
      if (pending) scrub(pending.snap);
    },

    releaseGenClips: () => {
      if (genClipIds.size === 0 && genAudioIds.size === 0) return;
      const { clips, audioClips } = get();
      const relClips = clips.filter((c) => genClipIds.has(c.id));
      const relAudio = audioClips.filter((c) => genAudioIds.has(c.id));
      // Every existing snapshot omitted these clips; splice them in at their
      // final state (matching what restoreDoc would have re-attached), so an
      // undo across the run's lifetime never drops a paid render.
      const graft = (snap: DocSnapshot) => {
        if (relClips.length > 0) {
          const have = new Set(snap.clips.map((c) => c.id));
          snap.clips = [...snap.clips, ...relClips.filter((c) => !have.has(c.id)).map((c) => ({ ...c }))].sort(
            (a, b) => a.start - b.start
          );
        }
        if (relAudio.length > 0) {
          const have = new Set(snap.audioClips.map((c) => c.id));
          snap.audioClips = [...snap.audioClips, ...relAudio.filter((c) => !have.has(c.id)).map((c) => ({ ...c }))];
        }
      };
      for (const snap of history) graft(snap);
      for (const snap of future) graft(snap);
      if (pending) graft(pending.snap);
      genClipIds.clear();
      genAudioIds.clear();
    },

    removeAudioById: (id) => removeGenPlacement(id, "audio"),

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
          (asset.type === "video" || asset.type === "image") &&
          asset.width !== undefined &&
          asset.height !== undefined &&
          s.clips.length === 0 &&
          !s.assets.some((a) => a.type === "video" || a.type === "image")
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
      const gone = st.assets.find((a) => a.id === id);
      if (!gone) return;
      // The media file dies with its last referencing asset — history
      // snapshots don't cover the asset list, so nothing can resurrect it.
      const dropFile = () => {
        const s = get();
        if (!s.projectId || s.assets.some((a) => a.fileName === gone.fileName)) return;
        void apiFetch(
          `/api/cut/projects/${s.projectId}/media/${encodeURIComponent(gone.fileName)}`,
          { method: "DELETE" }
        ).catch(() => {});
      };
      // An unreferenced asset is no doc edit: history snapshots don't cover
      // the asset list, so removing one must not open a checkpoint or churn
      // the clip arrays (a fresh clips reference would count as a doc change
      // and wipe the redo branch).
      if (
        !st.clips.some((c) => c.assetId === id) &&
        !st.audioClips.some((c) => c.assetId === id)
      ) {
        set((s) => ({ assets: s.assets.filter((a) => a.id !== id) }));
        dropFile();
        return;
      }
      push();
      // Cascade removes this asset's clips; every clip is free-positioned, so
      // the rest of the timeline (and its annotations) stays where it is.
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
          multiSelection,
          selection: keep(s.selection) ? s.selection : multiSelection[multiSelection.length - 1] ?? null,
        };
      });
      dropFile();
    },

    addClipFromAsset: (assetId, start) => {
      const asset = get().assets.find((a) => a.id === assetId);
      if (!asset || (asset.type !== "video" && asset.type !== "image")) return;
      push();
      const out = asset.type === "image" ? IMAGE_CLIP_SECONDS : asset.duration;
      const len = Math.max(MIN_LEN, out);
      const base = baseClips(get().clips);
      // An explicit target time always wins (a drop at the pointer, AI placing
      // b-roll against a voiceover). Without one: the first clip on an empty
      // base row anchors at 0 — a lone clip with dead space before it reads as
      // broken — and later clips append at the end of the row.
      const want = Math.max(0, start ?? (base.length === 0 ? 0 : totalDuration(get().clips)));
      const taken = footprints(base);
      const clip: VideoClip = {
        id: uid(),
        assetId,
        track: 0,
        start: nextFreeStart(taken, want, len),
        in: 0,
        out,
        muted: false,
      };
      set((s) => ({
        clips: [...s.clips, clip].sort((a, b) => a.start - b.start),
        ...sole({ kind: "clip", id: clip.id }),
      }));
    },

    addAudioFromAsset: (assetId, start, opts) => {
      const asset = get().assets.find((a) => a.id === assetId);
      if (!asset || asset.type !== "audio") return;
      push();
      // Within its lane the clip slides to the next free slot at or after the
      // target so it never lands on top of an existing sound.
      const want = Math.max(0, start ?? get().currentTime);
      const len = Math.max(MIN_LEN, asset.duration);
      const lane = opts?.lane ?? 0;
      const taken = footprints(get().audioClips.filter((a) => (a.lane ?? 0) === lane));
      const clip: AudioClip = {
        id: uid(),
        assetId,
        start: nextFreeStart(taken, want, len),
        in: 0,
        out: asset.duration,
        volume: 1,
        ...(opts?.duck !== undefined && opts.duck < 1
          ? { duck: Math.max(0, opts.duck) }
          : {}),
        ...(lane > 0 ? { lane } : {}),
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
      // Aim for the playhead but slide to the first lane's next free slot so
      // the new title never lands on top of an existing one.
      const taken = get()
        .overlays.filter((o) => (o.lane ?? 0) === 0)
        .map((o) => ({ start: o.start, end: o.end }));
      const start = nextFreeStart(taken, Math.min(t, Math.max(0, total - 0.5)), 3);
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

    // The non-transient updaters are just a checkpoint plus the live update.
    updateClip: (id, patch) => {
      push();
      get().updateClipTransient(id, patch);
    },

    setClipSpeed: (id, speed) => {
      const clip = get().clips.find((c) => c.id === id);
      if (!clip) return;
      const clamped = Math.max(SPEED_FLOOR, speed);
      if (Math.abs(clamped - clipSpeed(clip)) < 1e-4) return;
      resizeClipFootprint(clip, { speed: clamped }, Math.max(MIN_LEN, (clip.out - clip.in) / clamped));
    },

    setClipTrim: (id, nextIn, nextOut) => {
      const clip = get().clips.find((c) => c.id === id);
      if (!clip) return;
      if (Math.abs(nextIn - clip.in) < 1e-6 && Math.abs(nextOut - clip.out) < 1e-6) return;
      resizeClipFootprint(clip, { in: nextIn, out: nextOut }, (nextOut - nextIn) / clipSpeed(clip));
    },

    setClipTransition: (id, seconds, style) => {
      const s = get();
      const spans = getClipSpans(s.clips, s.assets);
      const idx = spans.findIndex((sp) => sp.clip.id === id);
      if (idx < 0) return;
      const clip = spans[idx].clip;
      const next = spans[idx + 1]?.clip;
      const value = Math.max(0, Math.min(TRANSITION_MAX, seconds));
      const newStyle = value > 0 ? (style ?? clip.transitionStyle ?? "crossfade") : undefined;
      const newOverlap = transitionOverlap(
        { ...clip, transition: value, transitionStyle: newStyle },
        next
      );
      push();
      get().updateClipTransient(id, {
        transition: value || undefined,
        // "crossfade" is the default — store it as absence to keep docs lean.
        transitionStyle: newStyle === "crossfade" ? undefined : newStyle,
      });
      // A dissolve is a physical overlap: setting one slides the next clip
      // (and the run behind it, gaps preserved) so it starts `newOverlap`
      // before this clip ends — closing any gap, since a dissolve needs
      // contact. Clearing one pushes the pair back to a hard cut. Edge styles
      // overlap nothing: they leave the layout alone. Only the base row moves:
      // transitions are a base-sequence concept, and the composited layers
      // stay pinned to the absolute times they annotate.
      if (next) {
        const oldOverlap = spans[idx].transitionOut;
        const wantStart =
          newOverlap > 0 ? clip.start + clipLen(clip) - newOverlap : next.start + oldOverlap;
        const delta = wantStart - next.start;
        if (Math.abs(delta) > 1e-6) {
          set((st) => ({
            clips: st.clips
              .map((c) =>
                c.track === 0 && c.start >= next.start - 1e-6
                  ? { ...c, start: Math.max(0, c.start + delta) }
                  : c
              )
              .sort((a, b) => a.start - b.start),
          }));
        }
      }
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

    updateAudiosTransient: (patches) =>
      set((s) => {
        const byId = new Map(patches.map((p) => [p.id, p.patch]));
        return {
          audioClips: s.audioClips.map((c) => {
            const patch = byId.get(c.id);
            return patch ? { ...c, ...patch } : c;
          }),
        };
      }),

    updateOverlayClipsTransient: (patches) =>
      set((s) => {
        const byId = new Map(patches.map((p) => [p.id, p.patch]));
        return {
          clips: s.clips.map((c) => {
            const patch = byId.get(c.id);
            return patch ? { ...c, ...patch } : c;
          }),
        };
      }),

    updateCuesTransient: (patches) =>
      set((s) => {
        const byId = new Map(patches.map((p) => [p.id, p.patch]));
        return {
          subtitles: {
            ...s.subtitles,
            cues: s.subtitles.cues.map((c) => {
              const patch = byId.get(c.id);
              return patch ? { ...c, ...patch } : c;
            }),
          },
        };
      }),

    updateClipTransient: (id, patch) =>
      set((s) => ({
        clips: s.clips.map((c) => (c.id === id ? { ...c, ...patch } : c)),
      })),

    updateClipsTransient: (patches) =>
      set((s) => {
        const byId = new Map(patches.map((p) => [p.id, p.patch]));
        return {
          clips: s.clips.map((c) => {
            const patch = byId.get(c.id);
            return patch ? { ...c, ...patch } : c;
          }),
        };
      }),

    sortClips: () =>
      set((s) => ({ clips: [...s.clips].sort((a, b) => a.start - b.start) })),

    updateAudioTransient: (id, patch) =>
      set((s) => ({
        audioClips: s.audioClips.map((c) =>
          c.id === id ? { ...c, ...patch } : c
        ),
      })),

    moveClip: (id, toIndex) => {
      // The AI reorder op: lift the clip out (its old spot becomes a gap) and
      // open a slot at the target index — the landing clip and everything
      // after it shift right by the moved footprint, everything else keeps
      // its absolute time, so audio, titles, and captions stay synced to the
      // clips they annotate. Pointer drags never come here — they free-place
      // through the lane coordinator.
      const base = baseClips(get().clips).sort((a, b) => a.start - b.start);
      const from = base.findIndex((c) => c.id === id);
      if (from < 0) return;
      const to = Math.max(0, Math.min(base.length - 1, toIndex));
      if (to === from) return;
      push();
      const moved = base[from];
      const others = base.filter((c) => c.id !== id);
      const len = clipLen(moved);
      const anchor = to < others.length ? others[to] : null;
      const newStart = anchor ? anchor.start : totalDuration(others);
      set((s) => ({
        clips: [
          ...overlayLayers(s.clips),
          ...others.map((c) =>
            c.start >= newStart - 1e-6 ? { ...c, start: c.start + len } : c
          ),
          { ...moved, start: newStart },
        ].sort((a, b) => a.start - b.start),
      }));
    },

    addVideoFromAsset: (assetId, place, start) => {
      const asset = get().assets.find((a) => a.id === assetId);
      if (!asset || (asset.type !== "video" && asset.type !== "image")) return;
      const out = asset.type === "image" ? IMAGE_CLIP_SECONDS : asset.duration;
      push();
      if (place.kind === "track" && place.track === 0) {
        const taken = footprints(baseClips(get().clips));
        const v: VideoClip = {
          id: uid(),
          assetId,
          track: 0,
          start: nextFreeStart(taken, Math.max(0, start), Math.max(MIN_LEN, out)),
          in: 0,
          out,
          muted: false,
        };
        set((s) => ({
          clips: [...s.clips, v].sort((a, b) => a.start - b.start),
          ...sole({ kind: "clip", id: v.id }),
        }));
        return;
      }
      // Full-frame by default: covers track 0 ("topmost plays"); the inspector
      // regions it (split half / corner PiP).
      const track = place.kind === "insert" ? place.level : place.track;
      const ov: VideoClip = {
        id: uid(),
        assetId,
        track,
        start: Math.max(0, start),
        in: 0,
        out,
        muted: false,
      };
      set((s) => ({
        clips: [...shiftTracksUp(s.clips, place), ov],
        ...sole({ kind: "clip", id: ov.id }),
      }));
    },

    dropVideoClip: (id, place, start) => {
      const src = get().clips.find((c) => c.id === id);
      if (!src) return;
      // No checkpoint here: the lane coordinator's drag gesture already pushed
      // one at pointer-down, so the whole move is a single undo step.
      const onBase = src.track === 0;

      if (place.kind === "track" && place.track === 0) {
        if (onBase) return; // a same-track move commits through the lane coordinator
        // Drop a layer clip down onto the base row: slide to its next free slot.
        const taken = footprints(baseClips(get().clips));
        const at = nextFreeStart(taken, Math.max(0, start), clipLen(src));
        set((st) => ({
          clips: st.clips.map((c) =>
            c.id === id ? { ...c, track: 0, start: at } : c
          ).sort((a, b) => a.start - b.start),
          ...sole({ kind: "clip", id }),
        }));
        return;
      }

      const track = place.kind === "insert" ? place.level : place.track;
      set((st) => {
        // Inserting a new track opens the slot by renumbering the others; the
        // moved clip itself is excluded from the shift, then placed at `track`.
        const shifted =
          place.kind === "insert" ? openInsertSlot(st.clips, place.level, id) : st.clips;
        return {
          clips: shifted
            .map((c) => (c.id === id ? { ...c, track, start: Math.max(0, start) } : c))
            .sort((a, b) => a.start - b.start),
          ...sole({ kind: "clip", id }),
        };
      });
    },

    updateOverlayClip: (id, patch) => {
      push();
      get().updateOverlayClipTransient(id, patch);
    },

    updateOverlayClipTransient: (id, patch) =>
      set((s) => ({
        clips: s.clips.map((c) => (c.id === id ? { ...c, ...patch } : c)),
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

      // A layer clip (not on the base row) selected: slice it in place. A base
      // clip falls through to the playhead-driven span split below.
      if (selection?.kind === "clip") {
        const c = get().clips.find((x) => x.id === selection.id);
        if (c && c.track !== 0) {
          const sp = c.speed && c.speed > 0 ? c.speed : 1;
          const eff = (c.out - c.in) / sp;
          if (t > c.start + 0.05 && t < c.start + eff - 0.05) {
            push();
            const cutIn = c.in + (t - c.start) * sp;
            const left: VideoClip = { ...c, out: cutIn };
            const right: VideoClip = { ...c, id: uid(), start: t, in: cutIn };
            set((s) => {
              const idx = s.clips.findIndex((x) => x.id === c.id);
              const next = [...s.clips];
              next.splice(idx, 1, left, right);
              return { clips: next, ...sole({ kind: "clip", id: right.id }) };
            });
          }
          return;
        }
      }

      // A title selected: both halves keep the full text and style.
      if (selection?.kind === "text") {
        const o = get().overlays.find((x) => x.id === selection.id);
        if (o && t > o.start + 0.05 && t < o.end - 0.05) {
          push();
          const left: TextOverlay = { ...o, end: t };
          const right: TextOverlay = { ...o, id: uid(), start: t };
          set((s) => ({
            overlays: s.overlays.flatMap((x) => (x.id === o.id ? [left, right] : [x])),
            ...sole({ kind: "text", id: right.id }),
          }));
        }
        return;
      }

      // A caption selected: word timings are absolute, so each half keeps the
      // words it covers and its text follows them; without timings the text
      // splits proportionally.
      if (selection?.kind === "cue") {
        const c = get().subtitles.cues.find((x) => x.id === selection.id);
        if (c && t > c.start + 0.05 && t < c.end - 0.05) {
          push();
          const lw = c.words?.filter((w) => w.t0 < t);
          const rw = c.words?.filter((w) => w.t0 >= t);
          const at = Math.round(c.text.length * ((t - c.start) / (c.end - c.start)));
          const left: SubtitleCue = {
            ...c,
            end: t,
            text: lw?.length ? lw.map((w) => w.w).join(" ") : c.text.slice(0, at).trim() || c.text,
            words: lw?.length ? lw : undefined,
          };
          const right: SubtitleCue = {
            ...c,
            id: uid(),
            start: t,
            text: rw?.length ? rw.map((w) => w.w).join(" ") : c.text.slice(at).trim() || c.text,
            words: rw?.length ? rw : undefined,
          };
          set((s) => ({
            subtitles: {
              ...s.subtitles,
              cues: s.subtitles.cues.flatMap((x) => (x.id === c.id ? [left, right] : [x])),
            },
            ...sole({ kind: "cue", id: right.id }),
          }));
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
      // dissolve into whatever came after. Both halves stay in place.
      const left: VideoClip = { ...span.clip, out: cutAt, transition: undefined, transitionStyle: undefined };
      const right: VideoClip = { ...span.clip, id: uid(), in: cutAt, start: t };
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
      const textIds = idsOf("text");
      const cueIds = idsOf("cue");
      // Every track is free-positioned: deleting leaves a gap and nothing
      // else moves, so annotations keep the timing they were placed at.
      set((s) => ({
        clips: s.clips.filter((c) => !clipIds.has(c.id)),
        audioClips: s.audioClips.filter((c) => !audioIds.has(c.id)),
        overlays: s.overlays.filter((o) => !textIds.has(o.id)),
        subtitles: {
          ...s.subtitles,
          cues: s.subtitles.cues.filter((c) => !cueIds.has(c.id)),
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
          if (sp) {
            add(sp.start, sp.start + sp.len);
          } else {
            // A layer clip carries no span (spans are the base row); use its
            // own footprint.
            const c = s.clips.find((x) => x.id === sel.id);
            if (c) {
              const speed = c.speed && c.speed > 0 ? c.speed : 1;
              add(c.start, c.start + Math.max(0.1, (c.out - c.in) / speed));
            }
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
          if (sp) {
            const mi = mediaFor(sp.clip.assetId);
            if (mi == null) continue;
            // Base-row clips re-materialize onto track 0 (asClip), so a template
            // stands up its own video instead of an empty timeline.
            layers.push({ media: mi, start: sp.start - start0, in: sp.clip.in, out: sp.clip.out, frame: sp.clip.frame, fit: sp.clip.fit, muted: sp.clip.muted, speed: sp.clip.speed, track: 1, asClip: true });
          } else {
            const c = s.clips.find((x) => x.id === sel.id);
            if (!c) continue;
            const mi = mediaFor(c.assetId);
            if (mi == null) continue;
            layers.push({ media: mi, start: c.start - start0, in: c.in, out: c.out, frame: c.frame, fit: c.fit, muted: c.muted, speed: c.speed, track: c.track + 1 });
          }
        } else if (sel.kind === "audio") {
          const c = s.audioClips.find((x) => x.id === sel.id);
          if (!c) continue;
          const mi = mediaFor(c.assetId);
          if (mi == null) continue;
          audio.push({ media: mi, start: c.start - start0, in: c.in, out: c.out, volume: c.volume, fadeIn: c.fadeIn, fadeOut: c.fadeOut, speed: c.speed, duck: c.duck, lane: c.lane });
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
      // Templates saved before the base-track removal persisted `onBase`;
      // read it as asClip so their footage still lands on track 0.
      const isClip = (l: (typeof usable)[number]) =>
        l.asClip ?? (l as { onBase?: boolean }).onBase;
      const clipLayers = usable.filter((l) => isClip(l));
      const overlayLayerDefs = usable.filter((l) => !isClip(l));
      // Clip layers append at the end of the current track 0; the
      // free-positioned parts (overlays, audio, captions) shift to line up with
      // that segment. A template with no clip layers drops in at the playhead.
      const shift = clipLayers.length ? totalDuration(get().clips) : Math.max(0, offset);
      const newClips: VideoClip[] = [...clipLayers]
        .sort((a, b) => a.start - b.start)
        .map((l) => ({
          track: 0,
          start: l.start + shift,
          id: uid(),
          assetId: assetIds[l.media],
          in: l.in,
          out: l.out,
          muted: l.muted,
          ...(l.frame ? { frame: l.frame } : {}),
          ...(l.fit ? { fit: l.fit } : {}),
          ...(l.speed ? { speed: l.speed } : {}),
        }));
      const topTrack = Math.max(0, ...overlayLayers(get().clips).map((c) => c.track));
      // Template layers store `track` as the source track + 1 (so a track-1
      // layer saved as 2, a track −1 backdrop as 0). Above-layers stack on top
      // of the project's current top; a backdrop (stored ≤ 0) goes back behind
      // the base row at its original negative level — never onto track 0, which
      // would splice it into the master sequence.
      const newLayers: VideoClip[] = overlayLayerDefs.map((l) => ({
        id: uid(),
        assetId: assetIds[l.media],
        track: l.track > 0 ? topTrack + l.track : l.track - 1,
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
          ...(a.lane ? { lane: a.lane } : {}),
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
        clips: [...s.clips, ...newClips, ...newLayers].sort((a, b) => a.start - b.start),
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
      const duration = projectDuration(s);
      const assetById = new Map(s.assets.map((a) => [a.id, a]));
      // Speech can live on the soundtrack or on a layer video track, not just
      // the base row. Layer-clip audio mixes into the transcribe pass as a
      // positioned source (exactly like a soundtrack clip), so dialogue carried
      // on a layer clip gets captioned and a layer-only cut still works.
      const audio = s.audioClips
        .filter((a) => !a.hidden && a.start < duration && assetById.has(a.assetId))
        .map((a) => ({
          file: assetById.get(a.assetId)!.fileName,
          in: a.in,
          out: a.out,
          start: a.start,
          volume: a.volume,
          speed: a.speed,
        }))
        .concat(
          overlayLayers(s.clips)
            .filter(
              (c) => !c.hidden && !c.muted && c.start < duration && assetById.has(c.assetId),
            )
            .map((c) => ({
              file: assetById.get(c.assetId)!.fileName,
              in: c.in,
              out: c.out,
              start: c.start,
              volume: 1,
              speed: c.speed,
            })),
        );
      if (spans.length === 0 && audio.length === 0) {
        set({ subtitleStatus: "error", subtitleError: "Add a video to the timeline first." });
        return;
      }
      // Generation targets the active subtitle track, with its own language.
      const lane = s.subtitleLane;
      const epoch = laneEpoch;
      const silentSpacer = (len: number) =>
        ({ file: "", in: 0, out: len, muted: true, speed: 1, transition: 0 });
      const spec = {
        duration,
        locale: trackLocale(s.subtitles, lane),
        // The transcribe mix is a sequential fold, so gaps between the
        // free-placed clips ship as explicit silent spacers (empty file). An
        // overlay-only cut has no track-0 spans: the whole bed is one spacer.
        clips:
          spans.length === 0
            ? [silentSpacer(duration)]
            : spanSequence(spans).flatMap(({ gapBefore, span: sp }) => [
                ...(gapBefore > 0 ? [silentSpacer(gapBefore)] : []),
                {
                  file: sp.asset.fileName,
                  in: sp.clip.in,
                  out: sp.clip.out,
                  muted: sp.clip.muted,
                  speed: clipSpeed(sp.clip),
                  // The clamped cross-dissolve overlap, so the transcribe mix
                  // overlaps clip audio the same way the timeline does and cues
                  // stay in sync.
                  transition: sp.transitionOut,
                },
              ]),
        audio,
      };
      set({ subtitleStatus: "running", subtitleError: null, subtitleStartedAt: Date.now() });
      try {
        const cues = await runTranscription(projectId, spec);
        if (cues === null) return; // switched projects mid-run
        if (laneEpoch !== epoch) return set(staleLaneError);
        // Only the active track's cues are replaced; other languages stay.
        const tagged = cues.map((c) => ({ ...c, ...(lane > 0 ? { lane } : {}) }));
        if (cues.length === 0) {
          // No speech in the audio — leave the other tracks untouched. This
          // still deletes the active track's cues (possibly hand-edited), so
          // it checkpoints like the replace path: ⌘Z brings them back.
          if (get().subtitles.cues.some((c) => (c.lane ?? 0) === lane)) push();
          set((cur) => ({
            subtitles: {
              ...cur.subtitles,
              cues: cur.subtitles.cues.filter((c) => (c.lane ?? 0) !== lane),
              generatedAt: Date.now(),
            },
            subtitleStatus: "empty",
          }));
          return;
        }
        push();
        set((cur) => ({
          subtitles: {
            ...cur.subtitles,
            cues: [
              ...cur.subtitles.cues.filter((c) => (c.lane ?? 0) !== lane),
              ...tagged,
            ].sort((a, b) => a.start - b.start),
            generatedAt: Date.now(),
          },
          subtitleStatus: "ready",
        }));
      } catch (err) {
        if (get().projectId !== projectId) return;
        set({
          subtitleStatus: "error",
          subtitleError: err instanceof Error ? err.message : String(err),
        });
      }
    },

    generateClipSubtitles: async (clipId) => {
      const s = get();
      if (!s.projectId) throw new Error("Open a project first.");
      if (s.subtitleStatus === "running") {
        throw new Error("Subtitles are already generating — try again in a moment.");
      }
      const projectId = s.projectId;
      const sp = getClipSpans(s.clips, s.assets).find((x) => x.clip.id === clipId);
      if (!sp) throw new Error("The clip is no longer on the timeline.");
      const lane = s.subtitleLane;
      const epoch = laneEpoch;
      // The clip's own sound, deliberately unmuted: this transcribes what the
      // clip says even when its timeline audio is muted.
      const spec = {
        duration: sp.len,
        locale: trackLocale(s.subtitles, lane),
        clips: [
          {
            file: sp.asset.fileName,
            in: sp.clip.in,
            out: sp.clip.out,
            muted: false,
            speed: clipSpeed(sp.clip),
            transition: 0,
          },
        ],
        audio: [],
      };
      set({ subtitleStatus: "running", subtitleError: null, subtitleStartedAt: Date.now() });
      try {
        const cues = await runTranscription(projectId, spec);
        if (cues === null) return; // switched projects mid-run
        if (laneEpoch !== epoch) {
          set(staleLaneError);
          throw new Error(staleLaneError.subtitleError);
        }
        // The job timed cues against the lone clip, so shift them (and their
        // word timings) onto the clip's timeline span. New cues replace any
        // on the active track that overlapped the clip; the rest of the
        // timeline — and every other track — keeps its cues.
        const placed = cues.map((c) => ({
          ...c,
          start: c.start + sp.start,
          end: c.end + sp.start,
          words: c.words?.map((w) => ({ ...w, t0: w.t0 + sp.start, t1: w.t1 + sp.start })),
          ...(lane > 0 ? { lane } : {}),
        }));
        if (placed.length > 0) push();
        set((cur) => {
          const kept = cur.subtitles.cues.filter(
            (c) =>
              (c.lane ?? 0) !== lane || !(c.end > sp.start && c.start < sp.start + sp.len)
          );
          const merged = [...kept, ...placed].sort((a, b) => a.start - b.start);
          return {
            subtitles: { ...cur.subtitles, cues: merged, generatedAt: Date.now() },
            subtitleStatus: merged.length > 0 ? "ready" : "empty",
          };
        });
      } catch (err) {
        // The clip panel reports the error; just clear the global busy flag.
        if (get().projectId === projectId) {
          set({ subtitleStatus: get().subtitles.cues.length > 0 ? "ready" : "idle" });
        }
        throw err;
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
      const lane = s.subtitleLane;
      const epoch = laneEpoch;
      set({ subtitleStatus: "running", subtitleError: null, subtitleStartedAt: Date.now() });
      try {
        const frames = await captureTimelineFrames(spans);
        if (frames.length === 0) throw new Error("Could not read any frames from the cut.");
        const res = await apiFetch("/api/cut/ai/visual-subtitles", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            frames,
            duration,
            locale: trackLocale(s.subtitles, lane),
          }),
        });
        const body = await apiJson<{
          cues?: { start: number; end: number; text: string }[];
        }>(res);
        if (!res.ok || !Array.isArray(body.cues)) {
          throw new Error(body.error ?? "Captioning failed.");
        }
        if (get().projectId !== projectId) return; // switched projects mid-run
        if (laneEpoch !== epoch) return set(staleLaneError);
        const cues: SubtitleCue[] = body.cues.map((c) => ({
          id: uid(),
          start: c.start,
          end: c.end,
          text: c.text,
          ...(lane > 0 ? { lane } : {}),
        }));
        push();
        set((cur) => ({
          subtitles: {
            ...cur.subtitles,
            cues: [
              ...cur.subtitles.cues.filter((c) => (c.lane ?? 0) !== lane),
              ...cues,
            ].sort((a, b) => a.start - b.start),
            generatedAt: Date.now(),
          },
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
      const lane = s.subtitleLane;
      const laneOf = (c: SubtitleCue) => c.lane ?? 0;
      // Need cues first — transcribe if the active track hasn't been captioned.
      if (!s.subtitles.cues.some((c) => laneOf(c) === lane)) {
        await s.generateSubtitles();
        if (!get().subtitles.cues.some((c) => laneOf(c) === lane)) return; // no speech, or an error
      }
      const projectId = get().projectId;
      // Apply the look right away for instant feedback, then rewrite the text.
      set((cur) => ({
        subtitles: { ...cur.subtitles, style },
        subtitleStatus: "running",
        subtitleError: null,
        subtitleStartedAt: Date.now(),
      }));
      // Rewrite only the active track — other languages keep their text.
      const cues = get().subtitles.cues.filter((c) => laneOf(c) === lane);
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

    translateSubtitleTrack: async (fromLane) => {
      const s = get();
      const lane = s.subtitleLane;
      if (!s.projectId || s.subtitleStatus === "running" || fromLane === lane) return;
      const laneOf = (c: SubtitleCue) => c.lane ?? 0;
      const source = s.subtitles.cues.filter((c) => laneOf(c) === fromLane);
      if (source.length === 0) return;
      const locale = trackLocale(s.subtitles, lane);
      const projectId = s.projectId;
      const epoch = laneEpoch;
      set({ subtitleStatus: "running", subtitleError: null, subtitleStartedAt: Date.now() });
      try {
        const res = await apiFetch("/api/cut/ai/captions", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            translateTo: locale,
            cues: source.map((c) => ({ start: c.start, end: c.end, text: c.text })),
          }),
        });
        const body = await apiJson<{ texts?: string[]; error?: string }>(res);
        if (get().projectId !== projectId) return;
        if (!res.ok || !Array.isArray(body.texts) || body.texts.length !== source.length) {
          throw new Error(body.error || "Could not translate the captions.");
        }
        if (laneEpoch !== epoch) return set(staleLaneError);
        push();
        const texts = body.texts;
        set((cur) => ({
          subtitles: {
            ...cur.subtitles,
            cues: [
              ...cur.subtitles.cues.filter((c) => laneOf(c) !== lane),
              ...source.map((c, i) => ({
                id: uid(),
                start: c.start,
                end: c.end,
                text: texts[i],
                ...(lane > 0 ? { lane } : {}),
              })),
            ].sort((a, b) => a.start - b.start),
            generatedAt: Date.now(),
          },
          subtitleStatus: "ready",
        }));
      } catch (err) {
        if (get().projectId !== projectId) return;
        set({
          subtitleStatus: "error",
          subtitleError: err instanceof Error ? err.message : String(err),
        });
      }
    },

    setSubtitlesView: (patch) =>
      set((s) => ({ subtitles: { ...s.subtitles, ...patch } })),

    setSubtitleLane: (lane) => {
      const count = Math.max(
        1,
        get().subtitles.tracks?.length ?? 0,
        ...get().subtitles.cues.map((c) => (c.lane ?? 0) + 1)
      );
      set({ subtitleLane: Math.max(0, Math.min(count - 1, lane)) });
    },

    addSubtitleTrack: (locale) => {
      const s = get();
      const count = Math.max(
        1,
        s.subtitles.tracks?.length ?? 0,
        ...s.subtitles.cues.map((c) => (c.lane ?? 0) + 1)
      );
      if (count >= MAX_SUBTITLE_LANES) return;
      push();
      // Materialize metas up to the new track so indices stay aligned.
      const tracks: SubtitleTrackMeta[] = Array.from(
        { length: count + 1 },
        (_, i) => s.subtitles.tracks?.[i] ?? {}
      );
      tracks[count] = { ...(locale ? { locale } : {}) };
      set((cur) => ({
        subtitles: { ...cur.subtitles, tracks },
        subtitleLane: count,
      }));
    },

    removeSubtitleTrack: (lane) => {
      const s = get();
      const count = Math.max(
        1,
        s.subtitles.tracks?.length ?? 0,
        ...s.subtitles.cues.map((c) => (c.lane ?? 0) + 1)
      );
      if (count <= 1) return;
      push();
      laneEpoch++; // lanes renumber: invalidate in-flight lane-targeted work
      const gone = new Set(
        s.subtitles.cues.filter((c) => (c.lane ?? 0) === lane).map((c) => c.id)
      );
      const keep = (sel: Selection) => !!sel && !(sel.kind === "cue" && gone.has(sel.id));
      set((cur) => {
        const tracks = Array.from(
          { length: count },
          (_, i) => cur.subtitles.tracks?.[i] ?? {}
        ).filter((_, i) => i !== lane);
        const multiSelection = cur.multiSelection.filter(keep);
        return {
          subtitles: {
            ...cur.subtitles,
            tracks,
            // The block-level legacy locale and dragged anchor described the
            // first track; when that track goes, they go with it — the
            // promoted track must not inherit the deleted one's language or
            // caption spot.
            ...(lane === 0 ? { locale: undefined, x: undefined, y: undefined } : {}),
            cues: cur.subtitles.cues
              .filter((c) => (c.lane ?? 0) !== lane)
              .map((c) => {
                const l = c.lane ?? 0;
                return l > lane ? { ...c, lane: l - 1 > 0 ? l - 1 : undefined } : c;
              }),
          },
          // The active lane follows its track: lanes above the removed one
          // shift down; removing the active one clamps into range.
          subtitleLane: Math.max(
            0,
            Math.min(count - 2, cur.subtitleLane > lane ? cur.subtitleLane - 1 : cur.subtitleLane)
          ),
          multiSelection,
          selection: keep(cur.selection)
            ? cur.selection
            : multiSelection[multiSelection.length - 1] ?? null,
        };
      });
    },

    setSubtitleTrackMeta: (lane, patch) =>
      set((s) => {
        const count = Math.max(
          1,
          s.subtitles.tracks?.length ?? 0,
          ...s.subtitles.cues.map((c) => (c.lane ?? 0) + 1),
          lane + 1
        );
        const tracks: SubtitleTrackMeta[] = Array.from(
          { length: count },
          (_, i) => s.subtitles.tracks?.[i] ?? {}
        );
        tracks[lane] = { ...tracks[lane], ...patch };
        return { subtitles: { ...s.subtitles, tracks } };
      }),

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
      const all = get().subtitles.cues;
      const cue = all.find((c) => c.id === id);
      if (!cue) return;
      // "Previous" means the previous cue on the same subtitle track.
      const cues = all
        .filter((c) => (c.lane ?? 0) === (cue.lane ?? 0))
        .sort((a, b) => a.start - b.start);
      const i = cues.findIndex((c) => c.id === id);
      if (i <= 0) return;
      push();
      const prev = cues[i - 1];
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
      const newSel: Selection[] = [];
      set((cur) => {
        let clips = cur.clips;
        let audioClips = cur.audioClips;
        let overlays = cur.overlays;
        // Every item aims for the playhead but respects what already sits on
        // its lane: an occupied spot slides the paste right to the next gap
        // that fits. Earlier items of this same paste count too.
        for (const cb of clipboard) {
          if (cb.kind === "clip") {
            // Collision is per-track: a clip lands clear of others on its own
            // row (the base row, or its layer).
            const taken = footprints(clips.filter((c) => c.track === cb.item.track));
            const clip: VideoClip = {
              ...cb.item,
              id: uid(),
              start: nextFreeStart(taken, t, clipLen(cb.item)),
            };
            clips = [...clips, clip].sort((a, b) => a.start - b.start);
            newSel.push({ kind: "clip", id: clip.id });
          } else if (cb.kind === "audio") {
            const taken = footprints(
              audioClips.filter((a) => (a.lane ?? 0) === (cb.item.lane ?? 0)),
            );
            const item: AudioClip = { ...cb.item, id: uid(), start: nextFreeStart(taken, t, clipLen(cb.item)) };
            audioClips = [...audioClips, item];
            newSel.push({ kind: "audio", id: item.id });
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
        return { clips, audioClips, overlays, selection: newSel[newSel.length - 1] ?? null, multiSelection: newSel };
      });
      return true;
    },

    undo: () => {
      flush(); // commit any uncommitted edit before stepping back
      const prev = history.pop();
      if (!prev) return;
      future.push(snapshot());
      restoreDoc(prev);
    },

    redo: () => {
      flush();
      const next = future.pop();
      if (!next) return;
      history.push(snapshot());
      if (history.length > HISTORY_CAP) history.shift();
      restoreDoc(next);
    },
  };
});

// Track real edits to the persistable doc so a deferred checkpoint (see push)
// knows whether an edit actually happened between capture and commit.
useEditor.subscribe((s, prev) => {
  if (
    s.clips !== prev.clips ||
    s.audioClips !== prev.audioClips ||
    s.overlays !== prev.overlays ||
    s.subtitles !== prev.subtitles
  )
    docSeq++;
});

/** The asset fields persisted in project.json — the projection autosave
 * writes, and the one its change detector compares (runtime fields like
 * thumbs/peaks must not mark the doc dirty). */
export function storedAssets(assets: MediaAsset[]): StoredAsset[] {
  return assets.map(({ id, fileName, name, type, duration, width, height, origin, chatId, language }) => ({
    id,
    fileName,
    name,
    type,
    duration,
    ...(width !== undefined ? { width } : {}),
    ...(height !== undefined ? { height } : {}),
    ...(origin !== undefined ? { origin } : {}),
    ...(chatId !== undefined ? { chatId } : {}),
    ...(language !== undefined ? { language } : {}),
  }));
}

/** The persistable slice of the editor state, for autosave. */
export function serializeDoc(s: {
  projectName: string;
  assets: MediaAsset[];
  clips: VideoClip[];
  audioClips: AudioClip[];
  overlays: TextOverlay[];
  aspect: Aspect;
  fadeIn: number;
  fadeOut: number;
  publish: { caption: string; tags: string; soundTitle: string; handle: string };
  notes: { text: string; publishedAt: string; links: string[] };
  subtitles: SubtitlesBlock;
  genvideo?: VideoProject;
}): Partial<ProjectDoc> {
  return {
    name: s.projectName,
    assets: storedAssets(s.assets),
    clips: s.clips,
    audioClips: s.audioClips,
    overlays: s.overlays,
    aspect: s.aspect,
    fadeIn: s.fadeIn,
    fadeOut: s.fadeOut,
    subtitles: s.subtitles,
    publish: { ...s.publish },
    notes: { ...s.notes, links: [...s.notes.links] },
    // Explicit null when there is no run: absence means "keep what you have"
    // to the PUT handler, so a dismissed plan could otherwise never be cleared.
    genvideo: s.genvideo ?? null,
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
  // Spans are the base row (track 0): the master sequence that carries
  // transitions and drives playback. Layer clips composite separately.
  // Map lookup, not a per-clip assets.find — this runs every playback frame.
  const byId = new Map(assets.map((a) => [a.id, a]));
  const present = clips
    .filter((clip) => clip.track === 0)
    .map((clip) => ({ clip, asset: byId.get(clip.assetId) }))
    .filter((x): x is { clip: VideoClip; asset: MediaAsset } => !!x.asset)
    .sort((a, b) => a.clip.start - b.clip.start);
  const spans: ClipSpan[] = [];
  for (let i = 0; i < present.length; i++) {
    const { clip, asset } = present[i];
    const len = clipLen(clip);
    const next = present[i + 1]?.clip;
    // A dissolve is a physical overlap with the next clip, capped by the
    // declared transition; clips dragged apart dissolve into nothing.
    const physical = next ? Math.max(0, clip.start + len - next.start) : 0;
    const overlap = Math.min(transitionOverlap(clip, next), physical);
    spans.push({ clip, asset, start: clip.start, len, transitionOut: overlap });
  }
  return spans;
}

/** End of video track 0: where its last clip runs out (clips are free-placed,
 * so gaps count toward this, they just play black). */
export function totalDuration(clips: VideoClip[]) {
  let end = 0;
  for (const c of clips) if (c.track === 0) end = Math.max(end, c.start + clipLen(c));
  return end;
}

/** A track-0 clip as older docs stored it: packed by array order, no `start`. */
type LegacyClip = Omit<VideoClip, "start"> & { start?: number };

/** Assign packed sequential starts (each clip after the previous, dissolves
 * overlapping): the layout older docs implied by array order. */
function packStarts(clips: LegacyClip[]): VideoClip[] {
  let t = 0;
  const out: VideoClip[] = [];
  for (let i = 0; i < clips.length; i++) {
    const clip = { ...clips[i], start: t } as VideoClip;
    const next = clips[i + 1] ? ({ ...clips[i + 1], start: 0 } as VideoClip) : undefined;
    t += clipLen(clip) - transitionOverlap(clip, next);
    out.push(clip);
  }
  return out;
}

/** Video track 0 as a gapless sequence for the sequential render graphs
 * (export, transcription): each span in start order, with the length of the
 * black/silent spacer that precedes it wherever the free-placed clips leave
 * the track empty. Sub-50ms gaps are treated as abutting. */
export function spanSequence(spans: ClipSpan[]): { gapBefore: number; span: ClipSpan }[] {
  const out: { gapBefore: number; span: ClipSpan }[] = [];
  let cursor = 0;
  for (const sp of spans) {
    const gap = sp.start - cursor;
    out.push({ gapBefore: gap > 0.05 ? gap : 0, span: sp });
    cursor = sp.start + sp.len - sp.transitionOut;
  }
  return out;
}

/** The playable length of the whole project: video track 0 plus anything that
 * runs past it on another video track or the soundtrack. Drives the timeline
 * extent, the seek clamp, and export length so content past track 0's end is
 * reachable. */
export function projectDuration(s: {
  clips: VideoClip[];
  audioClips: AudioClip[];
}): number {
  let end = 0;
  // Any clip on any track extends the timeline; a layer running past track 0's
  // end is still reachable.
  for (const c of s.clips) end = Math.max(end, c.start + clipLen(c));
  for (const a of s.audioClips) end = Math.max(end, a.start + clipLen(a));
  return Math.max(0, end);
}

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

export const useTotalDuration = () => useEditor((s) => totalDuration(s.clips));
