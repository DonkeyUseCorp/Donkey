"use client";

import { create } from "zustand";
import { useGenerate } from "./generate";
import { realSuite } from "./genvideo/adapters";
import { GEN_FPS, StoreEditorBridge } from "./genvideo/editorBridge";
import { VideoOrchestrator } from "./genvideo/orchestrator";
import type { RefAsset, Shot, VideoEvent, VideoPhase, VideoProject } from "./genvideo/types";
import { useEditor } from "./store";
import type { Aspect } from "./types";

// Brief-to-video ("generate a video") controller. It owns one VideoOrchestrator
// per open project and runs it browser-side, exactly where generation and the
// editor store live. The orchestrator plans up to the shot breakdown and stops
// (the confirmation gate); the user approves, then the shots render and land on
// the timeline live. State persists on ProjectDoc.genvideo, so a reload resumes
// a run in flight.
//
// Held outside the panels (like useGenerate) so switching tabs never orphans a
// multi-minute render.

export type SceneStatus = "planning" | "awaiting_approval" | "generating" | "done" | "failed";

export interface SceneRun {
  projectId: string;
  mode: "generated" | "provided";
  /** What the run is about, for the card heading. */
  title: string;
  status: SceneStatus;
  phase: VideoPhase;
  shots: Shot[];
  placed: number;
  total: number;
  logs: string[];
  error?: string;
  /** When the run began (planning), for the elapsed clock. */
  startedAt: number;
  /** When rendering began (approval) — the render timer counts from here, not
   * from the idle time spent at the confirmation gate. */
  renderStartedAt?: number;
  /** When the run reached done/failed, freezing the elapsed clock. */
  endedAt?: number;
}

/** M:SS for an elapsed millisecond span. */
export function formatDuration(ms: number): string {
  const t = Math.max(0, Math.floor(ms / 1000));
  return `${Math.floor(t / 60)}:${String(t % 60).padStart(2, "0")}`;
}

export interface StartSceneParams {
  brief?: string;
  fromAudioAssetId?: string;
  targetSeconds?: number;
  aspect?: Aspect;
  style?: string;
  referenceAssetIds?: string[];
  /** The chat thread that asked, so the run's media is tagged to it and stays
   * off the Media/Video/Image/Audio panels. */
  chatId?: string | null;
}

// One live orchestrator at a time (per open project). Kept out of zustand state
// so its identity churn never triggers a render; the reactive `run` mirror is.
let orchestrator: VideoOrchestrator | null = null;
/** The project the live orchestrator belongs to, for the project-switch pause. */
let orchestratorProjectId: string | null = null;

// A run pauses the moment its project stops being open: nothing may render or
// spend against a project the user has left. The pause also clears the dead
// orchestrator and the run mirror, so reopening the project resumes from the
// persisted plan below — a mirror left behind would mask the resume and trap
// the run on an aborted orchestrator.
useEditor.subscribe((s, prev) => {
  if (s.projectId !== prev.projectId) {
    if (orchestrator && orchestratorProjectId !== s.projectId) {
      orchestrator.abort();
      orchestrator = null;
      orchestratorProjectId = null;
    }
    const run = useGenScene.getState().run;
    if (run && run.projectId !== s.projectId) useGenScene.setState({ run: null });
  }
  // Resume the persisted plan once its project finishes loading. This lives on
  // the store, not a component, so a paid run resumes (and its media re-tags)
  // even when the AI panel never mounts. loadProject flips `loaded` false→true
  // in the same set() that fills genvideo, so the edge fires once per open.
  if (!s.loaded || prev.loaded || !s.projectId || !s.genvideo) return;
  if (orchestrator && orchestratorProjectId === s.projectId) return;
  if (useGenScene.getState().run?.projectId === s.projectId) return;
  useGenScene.getState().hydrate(s.projectId, s.genvideo);
});

const LOG_CAP = 24;
const CONCURRENCY = 3; // gentle on the video model's rate limit

const uid = () => crypto.randomUUID().slice(0, 8);
const isTerminal = (s: SceneStatus) => s === "done" || s === "failed";

/** Build a persistable RefAsset list from project asset ids the user pointed at.
 * Tagged "style" so they anchor both the reference images and every shot. */
function toReferences(ids: string[] | undefined): RefAsset[] {
  if (!ids?.length) return [];
  const assets = useEditor.getState().assets;
  const out: RefAsset[] = [];
  for (const id of ids) {
    const a = assets.find((x) => x.id === id);
    if (a) out.push({ mediaId: a.id, kind: a.type, purpose: "style", name: a.name });
  }
  return out;
}

function newProject(projectId: string, params: StartSceneParams): VideoProject {
  const audio = params.fromAudioAssetId
    ? useEditor.getState().assets.find((a) => a.id === params.fromAudioAssetId && a.type === "audio")
    : undefined;
  const mode: "generated" | "provided" = audio ? "provided" : "generated";
  return {
    id: `scene-${uid()}`,
    brief: params.brief?.trim() ?? "",
    references: toReferences(params.referenceAssetIds),
    audioMode: mode,
    ...(audio ? { audioAssetId: audio.id } : {}),
    ...(params.targetSeconds ? { targetSeconds: params.targetSeconds } : {}),
    fps: GEN_FPS,
    durationFrames: audio ? Math.round(audio.duration * GEN_FPS) : 0,
    transcript: [],
    // The plan owns its shape from the start (start() applies params.aspect to
    // an empty timeline before this runs), so a background render can never
    // pick up another open project's aspect.
    aspect: useEditor.getState().aspect,
    style: params.style?.trim() ?? "",
    suiteLabel: "donkey-hosted",
    ...(params.chatId ? { chatId: params.chatId } : {}),
    characters: [],
    locations: [],
    shots: [],
    phase: mode === "generated" ? "brief" : "ingest",
    breakdownApproved: false,
    createdAt: Date.now(),
    updatedAt: 0,
  };
}

/** The run's placed timeline clip ids (video track + soundtrack). */
function runClipIds(project: VideoProject): { clipIds: string[]; audioIds: string[] } {
  const clipIds = project.shots.map((s) => s.timelineClipId).filter((x): x is string => !!x);
  const audioIds = [
    ...(project.beatVoices ?? []).map((b) => b.voiceClipId),
    project.musicClipId,
  ].filter((x): x is string => !!x);
  return { clipIds, audioIds };
}

/** Every project asset id a run created (never the user's own references). */
function runAssetIds(project: VideoProject): Set<string> {
  const ids = new Set<string>();
  for (const sh of project.shots) {
    for (const id of [sh.startKeyframe, sh.endKeyframe, sh.clip, sh.voiceAssetId]) {
      if (id) ids.add(id);
    }
  }
  for (const bv of project.beatVoices ?? []) if (bv.voiceAssetId) ids.add(bv.voiceAssetId);
  if (project.musicAssetId) ids.add(project.musicAssetId);
  for (const va of [...project.characters, ...project.locations]) {
    if (va.mediaId) ids.add(va.mediaId);
  }
  return ids;
}

/** Re-assert chat ownership over everything a run created. New renders are
 * owned from creation (the chatId rides the generate job), but a run persisted
 * before that — or one whose asset landed while its project wasn't open — can
 * leave keyframes, shots, or narration sitting in the generate panels. Run on
 * hydrate, this re-tags those assets to the run's chat thread and drops any
 * panel job rows the run left behind (an errored render never landed an asset,
 * so its row is matched by the shot prompt it rendered). */
function claimRunMedia(projectId: string, project: VideoProject): void {
  const chatId = project.chatId;
  if (!chatId) return;
  const ids = runAssetIds(project);
  const editor = useEditor.getState();
  for (const a of editor.assets) {
    if (ids.has(a.id) && (a.origin !== "chat" || a.chatId !== chatId)) {
      editor.updateAsset(a.id, { origin: "chat", chatId });
    }
  }
  const prompts = new Set(
    project.shots.map((sh) => sh.lastPrompt).filter((p): p is string => !!p)
  );
  for (const j of useGenerate.getState().jobs) {
    if (j.chatId) continue; // already owned — the panels never saw it
    // Scoped to the run's own project: a prompt string alone must never match
    // (and delete) a render the user made themselves elsewhere.
    if (j.projectId !== projectId) continue;
    if ((j.assetId && ids.has(j.assetId)) || prompts.has(j.prompt)) {
      useGenerate.getState().dismiss(j.id);
    }
  }
}

/** Fold an orchestrator event into the reactive run mirror. */
function applyEvent(projectId: string, e: VideoEvent): void {
  useGenScene.setState((s) => {
    if (!s.run || s.run.projectId !== projectId) return s;
    const run = { ...s.run };
    switch (e.type) {
      case "phase":
        run.phase = e.phase;
        break;
      case "breakdown":
        run.shots = e.shots;
        run.total = e.shots.length;
        break;
      case "shot:update":
        run.shots = run.shots.map((sh) => (sh.id === e.shot.id ? e.shot : sh));
        break;
      case "progress":
        run.placed = e.placed;
        run.total = e.total;
        break;
      case "log":
        run.logs = [...run.logs, e.message].slice(-LOG_CAP);
        break;
      case "error":
        run.logs = [...run.logs, e.message].slice(-LOG_CAP);
        run.error = e.message;
        break;
    }
    return { run };
  });
}

/** Map the orchestrator's persisted project phase to a card status. */
function statusFor(p: VideoProject): SceneStatus {
  if (p.phase === "failed") return "failed";
  if (p.phase === "done") return "done";
  if (p.breakdownApproved) return "generating";
  // Unapproved: at the gate only once the plan exists. A run persisted
  // mid-planning must hydrate as planning — an Approve button with no shot
  // list behind it would render paid shots through a gate nobody reviewed.
  return p.shots.length > 0 ? "awaiting_approval" : "planning";
}

function syncFromProject(): void {
  const p = orchestrator?.project;
  if (!p) return;
  const status = statusFor(p);
  useGenScene.setState((s) => {
    if (!s.run) return s;
    const terminal = status === "done" || status === "failed";
    return {
      run: {
        ...s.run,
        phase: p.phase,
        shots: p.shots,
        total: p.shots.length,
        status,
        ...(terminal ? { endedAt: Date.now() } : {}),
      },
    };
  });
  // A finished run hands its clips to the user's undo domain — from here they
  // edit (and undo) like anything else. A regeneration adopts them back first.
  if (status === "done" || status === "failed") {
    useEditor.getState().releaseGenClips();
  }
}

function fail(message: string): void {
  useGenScene.setState((s) =>
    s.run ? { run: { ...s.run, status: "failed", error: message, endedAt: Date.now() } } : s
  );
  // Failed is terminal — whatever the run placed belongs to the user now.
  useEditor.getState().releaseGenClips();
}

/** Settle handlers scoped to one orchestrator: a superseded or paused run's
 * late resolution must never touch the run mirror — by the time it settles,
 * the mirror may belong to a fresh run in another project. */
function settled(orch: VideoOrchestrator): () => void {
  return () => {
    if (orchestrator === orch && !orch.isAborted) syncFromProject();
  };
}
function failed(orch: VideoOrchestrator): (e: unknown) => void {
  return (e) => {
    if (orchestrator === orch && !orch.isAborted) {
      fail(e instanceof Error ? e.message : String(e));
    }
  };
}

/** Rebuild a finished run from the open project's persisted plan so the
 * revision tools keep working after a reload. Built on demand — a done card
 * resurfaces only when the user actually revises, never just from opening the
 * project. Returns true once a live orchestrator and mirror exist. */
function resumeDoneRun(): boolean {
  const ed = useEditor.getState();
  const project = ed.genvideo;
  if (!ed.projectId || !project || project.phase !== "done") return false;
  orchestrator?.abort();
  const orch = buildOrchestrator(ed.projectId, project);
  orchestrator = orch;
  orchestratorProjectId = ed.projectId;
  useGenScene.setState({
    run: {
      projectId: ed.projectId,
      mode: project.audioMode,
      title: project.brief || "Animating your audio",
      status: "done",
      phase: project.phase,
      shots: project.shots,
      placed: project.shots.filter((s) => s.timelineClipId).length,
      total: project.shots.length,
      logs: [],
      startedAt: Date.now(),
      endedAt: Date.now(),
    },
  });
  return true;
}

function buildOrchestrator(projectId: string, project: VideoProject): VideoOrchestrator {
  return new VideoOrchestrator(project, {
    editor: new StoreEditorBridge(projectId),
    // project.chatId (persisted) owns the run's media, so tagging survives a
    // reload/resume, not just the initial turn.
    suite: realSuite(projectId, project.chatId),
    emit: (e) => applyEvent(projectId, e),
    // Persist only while this run's project is the open one — a superseded run
    // (the user switched projects) must never write its plan onto another.
    persist: (p) => {
      if (useEditor.getState().projectId !== projectId) return;
      useEditor.getState().setGenvideo(p);
    },
    concurrency: CONCURRENCY,
  });
}

interface GenSceneState {
  run: SceneRun | null;
  /** Plan a video and stop at the confirmation gate. Resolves once the shot
   * list is ready (or the run fails). */
  start: (
    projectId: string,
    params: StartSceneParams
  ) => Promise<{ started: boolean; shotCount?: number; message: string }>;
  /** Approve the shot plan — the shots render in the background from here. */
  approve: () => { ok: boolean; message: string };
  /** Redo one shot (1-based), optionally nudging it ("wider", "at night"). */
  regenerateShot: (n: number, note?: string) => { ok: boolean; message: string };
  /** Restyle the whole scene and redo every shot. */
  restyle: (style: string) => { ok: boolean; message: string };
  /** Rebuild + resume a persisted run when a project loads. */
  hydrate: (projectId: string, project: VideoProject) => void;
  dismiss: () => void;
}

export const useGenScene = create<GenSceneState>((set, get) => ({
  run: null,

  start: async (projectId, params) => {
    const cur = get().run;
    if (orchestrator && cur && cur.projectId === projectId && !isTerminal(cur.status)) {
      return { started: false, message: "A video is already being generated for this project." };
    }
    // Validate before any side effect — the aspect apply below reshapes the
    // timeline and must not run for a request that gets rejected.
    if (!params.fromAudioAssetId && !params.brief?.trim()) {
      return { started: false, message: "Tell me what the video should be about." };
    }
    // Only set the aspect on an empty timeline: reframing a project that already
    // has clips is a committing edit, and this runs before the approval gate.
    // Applied before newProject so the plan freezes the effective shape.
    const ed = useEditor.getState();
    if (params.aspect && ed.clips.length === 0 && ed.audioClips.length === 0) {
      ed.setAspect(params.aspect);
    }
    const project = newProject(projectId, params);
    if (project.audioMode === "generated" && !project.brief) {
      return { started: false, message: "Tell me what the video should be about." };
    }
    // Supersede any previous run so two orchestrators never write at once.
    orchestrator?.abort();
    const orch = buildOrchestrator(projectId, project);
    orchestrator = orch;
    orchestratorProjectId = projectId;
    set({
      run: {
        projectId,
        mode: project.audioMode,
        title: project.brief || "Animating your audio",
        status: "planning",
        phase: project.phase,
        shots: [],
        placed: 0,
        total: 0,
        logs: [],
        startedAt: Date.now(),
      },
    });
    try {
      await orch.run(); // resolves at the confirmation gate
    } catch (e) {
      const message = e instanceof Error ? e.message : String(e);
      failed(orch)(e);
      return { started: false, message };
    }
    if (orchestrator !== orch || orch.isAborted) {
      return { started: false, message: "This plan was superseded before it finished." };
    }
    syncFromProject();
    const p = orch.project;
    if (p.phase === "failed") {
      return { started: false, message: get().run?.error ?? "Planning failed." };
    }
    return {
      started: true,
      shotCount: p.shots.length,
      message: `Planned ${p.shots.length} shot${p.shots.length === 1 ? "" : "s"}. Approve to render.`,
    };
  },

  approve: () => {
    const run = get().run;
    if (!orchestrator || !run || run.status !== "awaiting_approval") {
      return { ok: false, message: "There's no video plan waiting to render." };
    }
    if (run.projectId !== useEditor.getState().projectId) {
      return { ok: false, message: "Open the plan's project to approve it." };
    }
    const orch = orchestrator;
    set({ run: { ...run, status: "generating", renderStartedAt: Date.now() } });
    orch.approveBreakdown().then(settled(orch)).catch(failed(orch));
    return { ok: true, message: "Rendering — shots land on the timeline as they finish." };
  },

  regenerateShot: (n, note) => {
    // After a reload the finished run has no live orchestrator — rebuild it
    // from the persisted plan before deciding the scene "isn't done".
    if (!orchestrator || !get().run) resumeDoneRun();
    const run = get().run;
    if (!orchestrator || !run || run.status !== "done") {
      return { ok: false, message: "The scene isn't finished rendering yet — revise it once it's done." };
    }
    const orch = orchestrator;
    const id = orch.shotIdByNumber(n);
    if (!id) return { ok: false, message: `This scene has no shot ${n}.` };
    // The run takes its clips back for the redo (they were released at done),
    // so the swap stays off the undo stack until it finishes again.
    const owned = runClipIds(orch.project);
    useEditor.getState().adoptGenClips(owned.clipIds, owned.audioIds);
    set({ run: { ...run, status: "generating", renderStartedAt: Date.now() } });
    const redo = note ? orch.applyShotNote(id, note) : orch.regenerateShots([id]);
    redo.then(settled(orch)).catch(failed(orch));
    return { ok: true, message: `Redoing shot ${n}…` };
  },

  restyle: (style) => {
    // Same reload path as regenerateShot: a finished run rebuilds on demand.
    if (!orchestrator || !get().run) resumeDoneRun();
    const run = get().run;
    if (!orchestrator || !run || run.status !== "done") {
      return { ok: false, message: "The scene isn't finished rendering yet — restyle it once it's done." };
    }
    const orch = orchestrator;
    // The run takes its clips back for the restyle (they were released at
    // done), so the swaps stay off the undo stack until it finishes again.
    const owned = runClipIds(orch.project);
    useEditor.getState().adoptGenClips(owned.clipIds, owned.audioIds);
    set({ run: { ...run, status: "generating", renderStartedAt: Date.now() } });
    orch.changeStyle(style).then(settled(orch)).catch(failed(orch));
    return { ok: true, message: "Restyling the whole scene…" };
  },

  hydrate: (projectId, project) => {
    // Re-assert chat ownership over the run's media before anything else, so
    // even a finished run's leftovers never sit in the generate panels.
    claimRunMedia(projectId, project);
    // A finished or failed run has nothing to resume — its clips are already on
    // the timeline — so it doesn't re-surface a card on reload. Revision tools
    // rebuild a done run on demand (resumeDoneRun).
    if (project.phase === "done" || project.phase === "failed") return;
    // Rebuild the orchestrator around the persisted plan so approve/regenerate
    // keep working after a reload. Supersede any prior run first so two never
    // both write.
    orchestrator?.abort();
    const orch = buildOrchestrator(projectId, project);
    orchestrator = orch;
    orchestratorProjectId = projectId;
    // The store's gen sets reset on load; re-mark this in-flight run's already
    // placed clips as render-owned so undo/redo stay off them as it finishes.
    const owned = runClipIds(project);
    useEditor.getState().adoptGenClips(owned.clipIds, owned.audioIds);
    set({
      run: {
        projectId,
        mode: project.audioMode,
        title: project.brief || "Animating your audio",
        status: statusFor(project),
        phase: project.phase,
        shots: project.shots,
        placed: project.shots.filter((s) => s.timelineClipId).length,
        total: project.shots.length,
        logs: [],
        // The original start time isn't persisted, so a resumed run's clock
        // counts from the reload.
        startedAt: Date.now(),
        ...(statusFor(project) === "generating" ? { renderStartedAt: Date.now() } : {}),
      },
    });
    // A run interrupted mid-generation picks itself back up, and one
    // interrupted mid-planning finishes its plan (run() stops at the gate by
    // construction); only a completed plan sitting at the gate waits.
    if (project.breakdownApproved || statusFor(project) === "planning") {
      orch.run().then(settled(orch)).catch(failed(orch));
    }
  },

  dismiss: () => {
    const run = get().run;
    // Dismissing an unrendered plan abandons it: the orchestrator stops and
    // the persisted plan is cleared, so it can't resurrect on the next load. A
    // finished (or failed) run keeps its record — its media re-tags from it on
    // load and nothing re-surfaces a terminal card.
    if (run && !isTerminal(run.status)) {
      orchestrator?.abort();
      orchestrator = null;
      orchestratorProjectId = null;
      if (useEditor.getState().projectId === run.projectId) {
        useEditor.getState().setGenvideo(undefined);
      }
    }
    set({ run: null });
  },
}));
