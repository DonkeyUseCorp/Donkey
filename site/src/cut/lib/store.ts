"use client";

import { create } from "zustand";
import type {
  Aspect,
  AudioClip,
  ClipSpan,
  MediaAsset,
  ProjectDoc,
  Selection,
  StoredAsset,
  SubtitleCue,
  SubtitlesBlock,
  TextOverlay,
  VideoClip,
} from "./types";
import { apiFetch } from "./api";
import { emptySubtitles, mediaUrl } from "./types";
import { loadUiState, saveUiState } from "./uiState";

const uid = () => crypto.randomUUID().slice(0, 8);

const MIN_LEN = 0.1;

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

interface EditorState {
  projectId: string | null;
  projectName: string;
  loaded: boolean;
  loadError: string | null;
  saveState: SaveState;

  assets: MediaAsset[];
  clips: VideoClip[];
  audioClips: AudioClip[];
  overlays: TextOverlay[];
  /** Output frame (9:16 vertical or 16:9 widescreen), persisted per project. */
  aspect: Aspect;
  selection: Selection;
  currentTime: number;
  playing: boolean;
  pxPerSec: number;
  /** Timeline panel height in px (drag the panel's top border to change). */
  timelineH: number;
  /** Timeline time under the mouse (iMovie skimmer); null when off the timeline. */
  skimTime: number | null;
  /** TikTok publishing metadata (caption, hashtags, sound title). */
  publish: { caption: string; tags: string; soundTitle: string; handle: string };
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
  addAsset: (asset: MediaAsset) => void;
  updateAsset: (id: string, patch: Partial<MediaAsset>) => void;
  /** Remove a project asset and any clips/audio that reference it. */
  removeAsset: (id: string) => void;
  /** Add a video clip from an asset. With `index`, insert at that position on
   * the magnetic video track; otherwise append. */
  addClipFromAsset: (assetId: string, index?: number) => void;
  addAudioFromAsset: (assetId: string, start?: number) => void;
  addOverlay: () => void;
  updateClip: (id: string, patch: Partial<VideoClip>) => void;
  updateAudio: (id: string, patch: Partial<AudioClip>) => void;
  updateOverlay: (id: string, patch: Partial<TextOverlay>) => void;
  /** Live-drag updates that should not create undo entries. */
  updateOverlayTransient: (id: string, patch: Partial<TextOverlay>) => void;
  updateClipTransient: (id: string, patch: Partial<VideoClip>) => void;
  updateAudioTransient: (id: string, patch: Partial<AudioClip>) => void;
  moveClip: (id: string, toIndex: number) => void;
  /** iMovie "Detach Audio": lift the selected clip's sound onto the
   * soundtrack track (and mute the clip) so it can be cut independently. */
  detachAudio: () => void;
  /** Split at the given time, or the playhead when omitted. */
  splitAtPlayhead: (at?: number) => void;
  setSkimTime: (t: number | null) => void;
  setPublish: (patch: Partial<{ caption: string; tags: string; soundTitle: string; handle: string }>) => void;
  /** Kick off (and poll) an on-device transcription of the current cut. */
  generateSubtitles: () => Promise<void>;
  setSubtitlesView: (patch: Partial<Pick<SubtitlesBlock, "showOnVideo" | "showOnTimeline" | "locale">>) => void;
  /** Commit a cue's edited text (empty text deletes the cue). */
  setCueText: (id: string, text: string) => void;
  /** Split a cue at a character offset — at real word timings when known. */
  splitCue: (id: string, charOffset: number) => void;
  mergeCueIntoPrev: (id: string) => void;
  deleteCue: (id: string) => void;
  updateCueTransient: (id: string, patch: Partial<SubtitleCue>) => void;
  sortCues: () => void;
  deleteSelection: () => void;
  select: (sel: Selection) => void;
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
  /** Copy the selected clip/audio/title to the timeline clipboard. */
  copySelection: () => boolean;
  /** Paste the clipboard at the playhead; selects the pasted item. */
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

/** Timeline clipboard (⌘C/⌘V) — survives across projects in one session. */
type Clipboard =
  | { kind: "clip"; item: VideoClip }
  | { kind: "audio"; item: AudioClip }
  | { kind: "text"; item: TextOverlay }
  | null;
let clipboard: Clipboard = null;

export const useEditor = create<EditorState>((set, get) => {
  const snapshot = (): DocSnapshot => {
    const { clips, audioClips, overlays, subtitles } = get();
    return {
      clips: clips.map((c) => ({ ...c })),
      audioClips: audioClips.map((c) => ({ ...c })),
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
    overlays: [],
    aspect: "9:16",
    selection: null,
    currentTime: 0,
    playing: false,
    pxPerSec: 60,
    timelineH: TIMELINE_H_DEFAULT,
    skimTime: null,
    publish: { caption: "", tags: "", soundTitle: "", handle: "" },
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
        overlays: [],
        aspect: "9:16",
        selection: null,
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
          overlays: doc.overlays,
          aspect: doc.aspect ?? "9:16",
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

    setAspect: (a) => set({ aspect: a }),

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
      if (!get().assets.some((a) => a.id === id)) return;
      push();
      set((s) => {
        const sel = s.selection;
        const selGone =
          (sel?.kind === "clip" && s.clips.some((c) => c.id === sel.id && c.assetId === id)) ||
          (sel?.kind === "audio" &&
            s.audioClips.some((c) => c.id === sel.id && c.assetId === id));
        return {
          assets: s.assets.filter((a) => a.id !== id),
          clips: s.clips.filter((c) => c.assetId !== id),
          audioClips: s.audioClips.filter((c) => c.assetId !== id),
          selection: selGone ? null : s.selection,
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
        return { clips, selection: { kind: "clip", id: clip.id } };
      });
    },

    addAudioFromAsset: (assetId, start) => {
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
      };
      set((s) => ({
        audioClips: [...s.audioClips, clip],
        selection: { kind: "audio", id: clip.id },
      }));
    },

    addOverlay: () => {
      push();
      const t = get().currentTime;
      const total = totalDuration(get().clips);
      const start = Math.min(t, Math.max(0, total - 0.5));
      const overlay: TextOverlay = {
        id: uid(),
        text: "Your text",
        start,
        end: Math.min(start + 3, Math.max(total, start + 3)),
        x: 0.5,
        y: 0.42,
        size: 88,
        font: "sf",
        weight: 700,
        color: "#FFFFFF",
        shadow: true,
        plate: false,
      };
      set((s) => ({
        overlays: [...s.overlays, overlay],
        selection: { kind: "text", id: overlay.id },
      }));
    },

    // The non-transient updaters are just a checkpoint plus the live update.
    updateClip: (id, patch) => {
      push();
      get().updateClipTransient(id, patch);
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
      };
      set((s) => ({
        audioClips: [...s.audioClips, audio],
        clips: s.clips.map((c) => (c.id === clip.id ? { ...c, muted: true } : c)),
        selection: { kind: "audio", id: audio.id },
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
            return { audioClips: next, selection: { kind: "audio", id: right.id } };
          });
          return;
        }
      }

      const spans = getClipSpans(clips, assets);
      const span = spans.find(
        (sp) => t > sp.start + 0.05 && t < sp.start + sp.len - 0.05
      );
      if (!span) return;
      push();
      const cutAt = span.clip.in + (t - span.start);
      const left: VideoClip = { ...span.clip, out: cutAt };
      const right: VideoClip = { ...span.clip, id: uid(), in: cutAt };
      set((s) => {
        const idx = s.clips.findIndex((c) => c.id === span.clip.id);
        const next = [...s.clips];
        next.splice(idx, 1, left, right);
        return { clips: next, selection: { kind: "clip", id: right.id } };
      });
    },

    deleteSelection: () => {
      const sel = get().selection;
      if (!sel) return;
      push();
      set((s) => ({
        clips: sel.kind === "clip" ? s.clips.filter((c) => c.id !== sel.id) : s.clips,
        audioClips:
          sel.kind === "audio"
            ? s.audioClips.filter((c) => c.id !== sel.id)
            : s.audioClips,
        overlays:
          sel.kind === "text"
            ? s.overlays.filter((o) => o.id !== sel.id)
            : s.overlays,
        subtitles:
          sel.kind === "cue"
            ? { ...s.subtitles, cues: s.subtitles.cues.filter((c) => c.id !== sel.id) }
            : s.subtitles,
        selection: null,
      }));
    },

    select: (sel) => set({ selection: sel }),

    seek: (t) => {
      const total = totalDuration(get().clips);
      set({ currentTime: Math.max(0, Math.min(total, t)) });
    },

    setPlaying: (p) => set({ playing: p }),
    setSkimTime: (t) => {
      if (get().skimTime !== t) set({ skimTime: t });
    },
    setPublish: (patch) => set((s) => ({ publish: { ...s.publish, ...patch } })),

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
        })),
        audio: s.audioClips
          .filter((a) => a.start < duration && assetById.has(a.assetId))
          .map((a) => ({
            file: assetById.get(a.assetId)!.fileName,
            in: a.in,
            out: a.out,
            start: a.start,
            volume: a.volume,
          })),
      };
      set({ subtitleStatus: "running", subtitleError: null });
      try {
        const res = await apiFetch(`/api/cut/projects/${projectId}/transcribe`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(spec),
        });
        const body = (await res.json()) as { id?: string; error?: string };
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

    setSubtitlesView: (patch) =>
      set((s) => ({ subtitles: { ...s.subtitles, ...patch } })),

    setCueText: (id, text) => {
      const trimmed = text.replace(/\s+/g, " ").trim();
      const cue = get().subtitles.cues.find((c) => c.id === id);
      if (!cue || cue.text === trimmed) return;
      push();
      set((s) => ({
        subtitles: {
          ...s.subtitles,
          cues: trimmed
            ? s.subtitles.cues.map((c) =>
                // Hand-edited text no longer matches the word timings.
                c.id === id ? { ...c, text: trimmed, words: undefined } : c
              )
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
      const sel = s.selection;
      if (!sel) return false;
      if (sel.kind === "clip") {
        const c = s.clips.find((x) => x.id === sel.id);
        if (!c) return false;
        clipboard = { kind: "clip", item: { ...c } };
      } else if (sel.kind === "audio") {
        const a = s.audioClips.find((x) => x.id === sel.id);
        if (!a) return false;
        clipboard = { kind: "audio", item: { ...a } };
      } else if (sel.kind === "text") {
        const o = s.overlays.find((x) => x.id === sel.id);
        if (!o) return false;
        clipboard = { kind: "text", item: { ...o } };
      } else {
        return false;
      }
      return true;
    },

    paste: () => {
      const cb = clipboard;
      if (!cb) return false;
      const s = get();
      // The copied item's media must still exist in this project.
      if (
        (cb.kind === "clip" || cb.kind === "audio") &&
        !s.assets.some((a) => a.id === cb.item.assetId)
      )
        return false;
      push();
      const t = s.currentTime;
      if (cb.kind === "clip") {
        // Insert after the clip under the playhead (end of track otherwise).
        const spans = getClipSpans(s.clips, s.assets);
        let index = s.clips.length;
        for (let i = 0; i < spans.length; i++) {
          if (t < spans[i].start + spans[i].len) {
            index = i + 1;
            break;
          }
        }
        const clip: VideoClip = { ...cb.item, id: uid() };
        set((cur) => ({
          clips: [...cur.clips.slice(0, index), clip, ...cur.clips.slice(index)],
          selection: { kind: "clip", id: clip.id },
        }));
      } else if (cb.kind === "audio") {
        const item: AudioClip = { ...cb.item, id: uid(), start: Math.max(0, t) };
        set((cur) => ({
          audioClips: [...cur.audioClips, item],
          selection: { kind: "audio", id: item.id },
        }));
      } else {
        const len = Math.max(0.2, cb.item.end - cb.item.start);
        const item: TextOverlay = { ...cb.item, id: uid(), start: Math.max(0, t), end: Math.max(0, t) + len };
        set((cur) => ({
          overlays: [...cur.overlays, item],
          selection: { kind: "text", id: item.id },
        }));
      }
      return true;
    },

    undo: () => {
      flush(); // commit any uncommitted edit before stepping back
      const prev = history.pop();
      if (!prev) return;
      future.push(snapshot());
      set({ ...prev, selection: null });
    },

    redo: () => {
      flush();
      const next = future.pop();
      if (!next) return;
      history.push(snapshot());
      if (history.length > HISTORY_CAP) history.shift();
      set({ ...next, selection: null });
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

/** The persistable slice of the editor state, for autosave. */
export function serializeDoc(s: {
  projectName: string;
  assets: MediaAsset[];
  clips: VideoClip[];
  audioClips: AudioClip[];
  overlays: TextOverlay[];
  aspect: Aspect;
  publish: { caption: string; tags: string; soundTitle: string; handle: string };
  subtitles: SubtitlesBlock;
}): Partial<ProjectDoc> {
  const assets: StoredAsset[] = s.assets.map(
    ({ id, fileName, name, type, duration, width, height }) => ({
      id,
      fileName,
      name,
      type,
      duration,
      ...(width !== undefined ? { width } : {}),
      ...(height !== undefined ? { height } : {}),
    })
  );
  return {
    name: s.projectName,
    assets,
    clips: s.clips,
    audioClips: s.audioClips,
    overlays: s.overlays,
    aspect: s.aspect,
    subtitles: s.subtitles,
    publish: { ...s.publish },
  };
}

export function clipLen(c: VideoClip | AudioClip) {
  return Math.max(MIN_LEN, c.out - c.in);
}

export function getClipSpans(
  clips: VideoClip[],
  assets: MediaAsset[]
): ClipSpan[] {
  // Map lookup, not a per-clip assets.find — this runs every playback frame.
  const byId = new Map(assets.map((a) => [a.id, a]));
  const spans: ClipSpan[] = [];
  let t = 0;
  for (const clip of clips) {
    const asset = byId.get(clip.assetId);
    if (!asset) continue;
    const len = clipLen(clip);
    spans.push({ clip, asset, start: t, len });
    t += len;
  }
  return spans;
}

export function totalDuration(clips: VideoClip[]) {
  return clips.reduce((sum, c) => sum + clipLen(c), 0);
}

export const useTotalDuration = () => useEditor((s) => totalDuration(s.clips));
