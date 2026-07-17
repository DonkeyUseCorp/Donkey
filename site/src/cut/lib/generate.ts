"use client";

import { useEffect } from "react";
import { create } from "zustand";
import { apiFetch, apiJson } from "./api";
import type { AssetRef } from "./assetRef";
import { bytesFromBase64 } from "./bytes";
import { composeGenPrompt, foldTextRefs } from "./composeGen";
import { stockAssetInDoc } from "./genvideo/docWriter";
import { hostedPost } from "./hosted";
import { enrichAsset, importFileToProject } from "./media";
import { refsToInlineImages, visualRefs, type InlineImage } from "./refMedia";
import { useGenNotify } from "./genNotify";
import { useImageGen } from "./imageGen";
import { useEditor } from "./store";
import { mediaUrl, type MediaAsset } from "./types";
import { videoModel } from "./videoGen";

// AI generation jobs, held outside the panels so a tab switch (which unmounts
// them) doesn't orphan a running generation — Veo renders take minutes.
//
// Generation runs on Donkey's hosted inference routes with the user's Donkey
// sign-in and credits. The cut hosts serve the same Next app and the auth
// cookie rides the registrable domain, so these are plain same-origin calls.
// Finished media lands back in the project through the local engine: videos
// upload as regular files, images bake into still clips.

export interface GenerateJob {
  id: string;
  projectId: string;
  kind: "image" | "video";
  prompt: string;
  /** Epoch ms when the render started — live cards show a ticking elapsed. */
  startedAt: number;
  status: "running" | "done" | "error";
  error?: string;
  /** The project asset the finished generation landed as. */
  assetId?: string;
  /** The chat thread that launched this render, when it wasn't the panel.
   * An owned job shows on its chat card only — the Video/Image panels list
   * panel renders, so they skip it — and its asset lands chat-tagged. */
  chatId?: string;
  /** The provider poll payload for an in-flight render — persisting it is what
   * lets a reload re-attach to the running job instead of orphaning it. */
  poll?: {
    id: string;
    provider: string;
    model: string;
    providerJobId?: string | null;
    providerGenerationId?: string | null;
    providerPollingUrl?: string | null;
    metadata?: Record<string, unknown>;
  };
}

interface GenerateState {
  /** Whether a Donkey session exists; null = not probed yet. */
  signedIn: boolean | null;
  jobs: GenerateJob[];
  probe: () => void;
  /** Awaitable probe, for callers that must know before acting (the AI
   * assistant's generate tools); resolves the fresh signed-in answer. */
  probeNow: () => Promise<boolean>;
  /** Kick off a generation. Returns when it settles, resolving to the final
   * job (status "done" with assetId, or "error" with a message) so the AI
   * assistant can act on the result; the panel just fires and forgets.
   * `refs` are references of any kind — images upload as-is, videos by a
   * captured poster frame, text files by their contents folded into the
   * prompt (see composeGen.ts). */
  generateImage: (
    projectId: string,
    prompt: string,
    opts?: {
      refs?: AssetRef[];
      aspect?: "16:9" | "9:16" | "1:1";
      resolution?: "1K" | "2K" | "4K";
      /** Rewrite the prompt around the references before rendering (the
       * default when refs are present) — see composeGen.ts. */
      composeRefs?: boolean;
      /** The owning chat thread when chat (or a scene run) asked — stamps the
       * job and the landed asset, keeping both off the generate panels. */
      chatId?: string;
    }
  ) => Promise<GenerateJob>;
  /** Kick off a video render. Returns the job id right away (the render
   * outlives most callers) plus the settled job for anyone who waits. */
  generateVideo: (
    projectId: string,
    prompt: string,
    opts?: VideoGenOptions
  ) => { jobId: string; settled: Promise<GenerateJob> };
  dismiss: (id: string) => void;
  /** Re-attach the poll loop of every persisted running render (reload
   * recovery) — called once when the app boots. Idempotent. */
  resumeRunningJobs: () => void;
}

export interface VideoGenOptions {
  tier?: "fast" | "high";
  durationSeconds?: number;
  /** Composition shape; defaults to the project's orientation. */
  aspect?: "16:9" | "9:16";
  resolution?: "720p" | "1080p";
  /** Person-safety for the render. Unset, Veo blocks person/face generation, so
   * any shot with a character fails. ALLOW_ADULT is the most any image input
   * permits (first-frame seed and reference images alike); ALLOW_ALL (needed
   * for minors) only works text-to-video. */
  personGeneration?: "DONT_ALLOW" | "ALLOW_ADULT" | "ALLOW_ALL";
  /** References of any kind — video, image, text file. Veo takes one
   * input image, so at most one picture seeds the render. */
  refs?: AssetRef[];
  /** Identity anchors (Veo 3.1 asset references, up to three): the render
   * keeps these characters/objects/scenes consistent instead of playing one
   * as the first frame. Mutually exclusive with a `refs` image seed; the
   * prompt rides as written (no compose rewrite). */
  referenceImages?: AssetRef[];
  /** Rewrite the prompt around the references before rendering (the
   * default when refs are present) — see composeGen.ts. Veo plays the
   * input image as the literal first frame, so a prompt that transforms
   * the reference must become a standalone description with the image
   * dropped; the rewrite decides which. Character mode passes false — the
   * poster seed is the point. */
  composeRefs?: boolean;
  /** Called once with the landed asset when the render completes and the
   * project is still open — lets the AI place the clip after a background
   * render it couldn't wait out (the assistant tool bridge caps at 2min). */
  onDone?: (asset: MediaAsset) => void;
  /** The owning chat thread when chat (or a scene run) asked — stamps the
   * job and the landed asset, keeping both off the generate panels. */
  chatId?: string;
}

const REFRESH_MS = 8000;
const VIDEO_DEADLINE_MS = 12 * 60_000;

const uid = () => crypto.randomUUID().slice(0, 8);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Display name for the asset: the prompt, tidied and capped. */
const promptName = (prompt: string) => {
  const line = prompt.trim().replace(/\s+/g, " ");
  return line.length > 60 ? `${line.slice(0, 57)}…` : line;
};

const promptSlug = (prompt: string) =>
  prompt
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 40) || "generated";

/** The Donkey sign-in URL for the current host (cut.* → apex). Image, video,
 * and voiceover all run on the user's Donkey account, so every generation
 * surface links here when signed out. */
export function signInUrl(): string {
  if (typeof window === "undefined") return "/sign-in";
  const { protocol, host, href } = window.location;
  // Sign-in runs on the apex (Google's redirect_uri is pinned there), but bring
  // the user back to the Cut page they started from once it completes.
  const apex = `${protocol}//${host.replace(/^cut\./, "")}`;
  return `${apex}/sign-in?callbackURL=${encodeURIComponent(href)}`;
}

/** Shown for any 402 (empty balance) across chat and generation tiles. The
 * chat error box and the job tiles match this text to swap in a "reload here"
 * credits link, so keep it and those call sites in sync. */
export const NO_CREDITS_MESSAGE = "No credits left";

/** The Donkey settings page where credits are bought (cut.* → apex). Linked
 * from any generation error caused by an empty balance. */
export function creditsUrl(): string {
  if (typeof window === "undefined") return "/app/settings";
  const { protocol, host } = window.location;
  const apex = `${protocol}//${host.replace(/^cut\./, "")}`;
  return `${apex}/app/settings`;
}

/** Creation-time ownership for generated media, in one place so the rule can't
 * drift per call site: chat-owned media lives on its chat card — never a
 * generate-panel row or arrival badge — and everything else is a panel render
 * (origin "generated", so it stays out of the Media panel's user imports). */
export function applyOwnership(asset: MediaAsset, chatId: string | undefined | null): void {
  if (chatId) {
    asset.origin = "chat";
    asset.chatId = chatId;
  } else {
    asset.origin = "generated";
  }
}

interface GenerationOutput {
  dataBase64?: string;
  contentType?: string;
  filename?: string;
  url?: string;
}

interface GenerationResponse {
  id: string;
  status: string;
  provider: string;
  model: string;
  providerJobId: string | null;
  providerGenerationId: string | null;
  providerPollingUrl: string | null;
  outputs: GenerationOutput[];
  error?: unknown;
  metadata?: Record<string, unknown>;
}

async function readError(res: Response, fallback: string): Promise<string> {
  if (res.status === 401) return "Sign in to Donkey to generate media.";
  const body = (await res.json().catch(() => null)) as {
    error?: unknown;
    message?: unknown;
    details?: { message?: unknown } | null;
  } | null;
  const message = [body?.message, body?.error].find(
    (v): v is string => typeof v === "string" && v.length > 0
  );
  if (res.status === 402) return NO_CREDITS_MESSAGE;
  // The provider tucks the real reason (a safety block, a rejected prompt) under
  // details.message; the top-level message is only a generic headline. Append it so a
  // failure explains itself instead of stopping at "…generation failed."
  const detail =
    typeof body?.details?.message === "string" && body.details.message.trim()
      ? body.details.message.trim()
      : null;
  if (detail && detail !== message) return message ? `${message} ${detail}` : detail;
  return message ?? fallback;
}

const providerError = (error: unknown): string | null => {
  if (typeof error === "string" && error) return error;
  if (error && typeof error === "object" && "message" in error) {
    const m = (error as { message?: unknown }).message;
    if (typeof m === "string" && m) return m;
  }
  return null;
};

/** Resolve a generation's prompt + input images from its refs. Runs the shared
 * compose step (see composeGen.ts) unless the caller opted out; on a compose
 * failure, falls back to the visual refs as-is with text-ref contents folded
 * into the prompt. `maxImages` caps what the generator accepts (Veo: 1). */
async function promptAndImages(
  target: "video" | "image",
  prompt: string,
  refs: AssetRef[],
  compose: boolean,
  maxImages: number
): Promise<{ prompt: string; images: InlineImage[] }> {
  if (refs.length === 0) return { prompt, images: [] };
  if (compose) {
    const composed = await composeGenPrompt(target, prompt, refs);
    if (composed) return { prompt: composed.prompt, images: composed.images.slice(0, maxImages) };
  }
  return {
    prompt: await foldTextRefs(prompt, refs),
    images: await refsToInlineImages(visualRefs(refs).slice(0, maxImages)),
  };
}

/** Video jobs persist per browser: settled ones so an unplaced render (a chat
 * card, the Video panel's renders list) survives a reload, and running ones
 * with their provider poll payload so a reload RE-ATTACHES to the in-flight
 * render (resumeRunningJobs) instead of orphaning credits already spent. A
 * running job persisted without a payload (it died before the provider
 * answered) restores as an error. */
const JOBS_KEY = "cut-gen-video-jobs";
const JOBS_CAP = 50;

/** Awaitable settlements for in-flight renders, fresh and reload-resumed —
 * how a resumed caller (the scene pipeline) adopts a running job's result
 * instead of billing a second take. */
const settlements = new Map<string, Promise<GenerateJob>>();

/** The settled-job promise for a running render, when this session owns it. */
export function videoJobSettlement(jobId: string): Promise<GenerateJob> | undefined {
  return settlements.get(jobId);
}

function readPersistedJobs(): GenerateJob[] {
  try {
    const v = JSON.parse(localStorage.getItem(JOBS_KEY) ?? "[]") as unknown;
    if (!Array.isArray(v)) return [];
    return (v as GenerateJob[])
      .filter((j) => j?.id)
      .map((j) =>
        j.status === "running" && !j.poll
          ? { ...j, status: "error" as const, error: "Interrupted by a reload before the render started." }
          : j
      );
  } catch {
    return [];
  }
}

function persistJobs(jobs: GenerateJob[]) {
  try {
    localStorage.setItem(
      JOBS_KEY,
      JSON.stringify(
        jobs
          .filter((j) => j.kind === "video" && (j.status !== "running" || j.poll))
          .slice(0, JOBS_CAP)
      )
    );
  } catch {
    // Storage full/blocked — render history just won't persist.
  }
}

export const useGenerate = create<GenerateState>((set, get) => {
  // A single session probe is in flight at a time, but the answer stays
  // re-checkable for the page's whole life: a sign-in can complete in another
  // tab, or the session cookie can land a beat after this page loads.
  let probing: Promise<boolean> | null = null;

  const update = (id: string, patch: Partial<GenerateJob>) => {
    set((s) => ({ jobs: s.jobs.map((j) => (j.id === id ? { ...j, ...patch } : j)) }));
    persistJobs(get().jobs);
  };

  const fail = (id: string, err: unknown) =>
    update(id, { status: "error", error: err instanceof Error ? err.message : String(err) });

  // The job after it has settled, for callers that awaited the run.
  const settled = (id: string, fallback: GenerateJob): GenerateJob =>
    get().jobs.find((j) => j.id === id) ?? fallback;

  // The media file exists either way. The open project records it in the live
  // store; a closed one records it in its persisted doc so nothing the render
  // made is orphaned. Returns whether the OPEN project adopted it (badges and
  // placement callbacks only make sense on screen).
  const adopt = (projectId: string, asset: MediaAsset): boolean => {
    if (useEditor.getState().projectId !== projectId) {
      void stockAssetInDoc(projectId, asset).catch(() => {});
      return false;
    }
    useEditor.getState().addAsset(asset);
    void enrichAsset(asset);
    return true;
  };

  /** Poll an in-flight Veo render to completion and land its file as a project
   * asset — the shared tail of a fresh render and a reload-resumed one. Keeps
   * the job's poll payload fresh so the NEXT reload re-attaches too. */
  const finishVideo = async (
    jobId: string,
    first: GenerationResponse,
    onDone?: (asset: MediaAsset) => void
  ): Promise<void> => {
    const job = get().jobs.find((j) => j.id === jobId);
    if (!job) return;
    let gen = first;
    // A resumed render keeps its original deadline, floored so a reload near
    // the limit still gets a couple of polls before giving up.
    const deadline = Math.max(job.startedAt + VIDEO_DEADLINE_MS, Date.now() + 2 * 60_000);
    while (gen.status === "in_progress") {
      update(jobId, {
        poll: {
          id: gen.id,
          provider: gen.provider,
          model: gen.model,
          providerJobId: gen.providerJobId,
          providerGenerationId: gen.providerGenerationId,
          providerPollingUrl: gen.providerPollingUrl,
          metadata: gen.metadata ?? {},
        },
      });
      if (Date.now() > deadline) throw new Error("Veo is taking too long — try again.");
      await sleep(REFRESH_MS);
      const poll = await hostedPost("/api/inference/assets/refresh", {
        id: gen.id,
        kind: "video",
        provider: gen.provider,
        model: gen.model,
        providerJobId: gen.providerJobId,
        providerGenerationId: gen.providerGenerationId,
        providerPollingUrl: gen.providerPollingUrl,
        metadata: gen.metadata ?? {},
      });
      if (!poll.ok) throw new Error(await readError(poll, "Video generation failed."));
      gen = (await poll.json()) as GenerationResponse;
    }
    if (gen.status !== "completed") {
      throw new Error(providerError(gen.error) ?? "Video generation failed.");
    }

    const out = gen.outputs.find((o) => o.dataBase64) ?? gen.outputs.find((o) => o.url);
    const fileName = `ai-${promptSlug(job.prompt)}.mp4`;
    let file: File;
    if (out?.dataBase64) {
      file = new File([bytesFromBase64(out.dataBase64)], fileName, {
        type: out.contentType ?? "video/mp4",
      });
    } else if (out?.url) {
      const dl = await fetch(out.url);
      if (!dl.ok) throw new Error("Could not download the generated video.");
      file = new File([await dl.arrayBuffer()], fileName, {
        type: out.contentType ?? "video/mp4",
      });
    } else {
      throw new Error("The provider returned no video.");
    }

    const asset = await importFileToProject(job.projectId, file);
    if (!asset) throw new Error("Could not import the generated video.");
    asset.name = promptName(job.prompt);
    applyOwnership(asset, job.chatId);
    if (adopt(job.projectId, asset)) {
      if (!job.chatId) useGenNotify.getState().landed("video", asset.id);
      onDone?.(asset);
    }
    update(jobId, { status: "done", assetId: asset.id, poll: undefined });
  };

  return {
    signedIn: null,
    jobs: typeof window === "undefined" ? [] : readPersistedJobs(),

    probe: () => {
      void get().probeNow();
    },

    probeNow: () => {
      probing ??= fetch("/api/auth/get-session", { cache: "no-store" })
        .then((r) => (r.ok ? r.json() : null))
        .then((s) => {
          const signedIn = Boolean((s as { user?: unknown } | null)?.user);
          set({ signedIn });
          return signedIn;
        })
        // A transient failure shouldn't knock a known session back to signed-out;
        // only fall to false when we never learned otherwise.
        .catch(() => {
          const signedIn = get().signedIn ?? false;
          set({ signedIn });
          return signedIn;
        })
        .finally(() => {
          probing = null;
        });
      return probing;
    },

    generateImage: (projectId, prompt, opts) => {
      const job: GenerateJob = {
        id: uid(),
        projectId,
        kind: "image",
        prompt,
        startedAt: Date.now(),
        status: "running",
        ...(opts?.chatId ? { chatId: opts.chatId } : {}),
      };
      set((s) => ({ jobs: [job, ...s.jobs] }));
      return (async () => {
        try {
          const aspect = opts?.aspect ?? useEditor.getState().aspect;
          const resolution = opts?.resolution ?? useImageGen.getState().resolution;
          // The job (and the landed asset's name) keeps the user's own words;
          // only the render sees the composed prompt. The image model takes
          // several input images, so every kept reference rides along.
          const { prompt: sent, images } = await promptAndImages(
            "image",
            prompt,
            opts?.refs ?? [],
            opts?.composeRefs !== false,
            Infinity
          );
          const res = await hostedPost("/api/inference/assets", {
            kind: "image",
            prompt: sent,
            ...(images.length > 0 ? { inputs: { images } } : {}),
            // The image model takes a real frame + detail via imageConfig; no prompt steering.
            parameters: { aspectRatio: aspect, imageSize: resolution },
          });
          if (!res.ok) throw new Error(await readError(res, "Image generation failed."));
          const gen = (await res.json()) as GenerationResponse;
          const out = gen.outputs.find((o) => o.dataBase64);
          if (!out?.dataBase64) throw new Error("The provider returned no image.");

          const form = new FormData();
          form.append(
            "file",
            new Blob([bytesFromBase64(out.dataBase64)], {
              type: out.contentType ?? "image/png",
            }),
            out.filename ?? "image.png"
          );
          form.append("name", promptName(prompt));
          // Mark it generated so it surfaces in the generate panel; a stock
          // image imported from a tile sends no origin (plain import).
          form.append("origin", "generated");
          const baked = await apiFetch(`/api/cut/projects/${projectId}/image`, {
            method: "POST",
            body: form,
          });
          const body = await apiJson<MediaAsset>(baked);
          if (!baked.ok || !body.fileName) {
            throw new Error(body.error ?? "Could not add the image to the project.");
          }
          const asset: MediaAsset = { ...body, url: mediaUrl(projectId, body.fileName) };
          applyOwnership(asset, opts?.chatId);
          if (adopt(projectId, asset) && !opts?.chatId) {
            useGenNotify.getState().landed("image", asset.id);
          }
          update(job.id, { status: "done", assetId: asset.id });
        } catch (err) {
          fail(job.id, err);
        }
        return settled(job.id, job);
      })();
    },

    generateVideo: (projectId, prompt, opts) => {
      const job: GenerateJob = {
        id: uid(),
        projectId,
        kind: "video",
        prompt,
        startedAt: Date.now(),
        status: "running",
        ...(opts?.chatId ? { chatId: opts.chatId } : {}),
      };
      set((s) => ({ jobs: [job, ...s.jobs] }));
      const settledRun = (async () => {
        try {
          // The job (and the landed asset's name) keeps the user's own words;
          // only the render sees the composed prompt. Veo seeds from a single
          // first-frame image, so at most one kept picture rides along.
          // Identity anchors travel separately: with referenceImages set, the
          // prompt stands as written and no seed image rides (Veo takes one
          // or the other).
          const tier = opts?.tier === "high" ? "high" : "fast";
          const anchors = opts?.referenceImages?.length
            ? await refsToInlineImages(
                visualRefs(opts.referenceImages).slice(0, videoModel(tier).maxReferenceImages)
              )
            : [];
          const { prompt: sent, images } = anchors.length
            ? { prompt, images: [] }
            : await promptAndImages("video", prompt, opts?.refs ?? [], opts?.composeRefs !== false, 1);
          const res = await hostedPost("/api/inference/assets", {
            kind: "video",
            prompt: sent,
            ...(anchors.length > 0
              ? { inputs: { referenceImages: anchors } }
              : images.length > 0
                ? { inputs: { images } }
                : {}),
            parameters: {
              tier,
              aspectRatio: opts?.aspect ?? useEditor.getState().aspect,
              ...(opts?.resolution ? { resolution: opts.resolution } : {}),
              ...(opts?.durationSeconds ? { durationSeconds: opts.durationSeconds } : {}),
              ...(opts?.personGeneration ? { personGeneration: opts.personGeneration } : {}),
            },
          });
          if (!res.ok) throw new Error(await readError(res, "Video generation failed."));
          const gen = (await res.json()) as GenerationResponse;
          await finishVideo(job.id, gen, opts?.onDone);
        } catch (err) {
          fail(job.id, err);
        }
        return settled(job.id, job);
      })();
      settlements.set(job.id, settledRun);
      return { jobId: job.id, settled: settledRun };
    },

    resumeRunningJobs: () => {
      for (const j of get().jobs) {
        if (j.kind !== "video" || j.status !== "running" || !j.poll || settlements.has(j.id)) continue;
        const poll = j.poll;
        const run = (async () => {
          try {
            // Re-enter the poll loop where the last session left it. The
            // timeline placement callback (onDone) is a closure and cannot
            // survive a reload — the asset still lands on its card/panel.
            await finishVideo(j.id, {
              status: "in_progress",
              outputs: [],
              ...poll,
            } as GenerationResponse);
          } catch (err) {
            fail(j.id, err);
          }
          return settled(j.id, j);
        })();
        settlements.set(j.id, run);
      }
    },

    dismiss: (id) => {
      set((s) => ({ jobs: s.jobs.filter((j) => j.id !== id) }));
      persistJobs(get().jobs);
    },
  };
});

// Reload recovery: re-attach every persisted in-flight render as soon as the
// app boots, so a refresh never orphans credits already spent.
if (typeof window !== "undefined") {
  setTimeout(() => useGenerate.getState().resumeRunningJobs(), 0);
}

/** Donkey sign-in state for the generation surfaces. Probes on mount and again
 * whenever the tab regains focus, so signing in — in this tab's round trip or a
 * separate tab — flips the UI without a manual reload. Null until first known. */
export function useSignedIn(): boolean | null {
  const signedIn = useGenerate((s) => s.signedIn);
  useEffect(() => {
    const probe = () => useGenerate.getState().probe();
    probe();
    const onVisible = () => {
      if (document.visibilityState === "visible") probe();
    };
    window.addEventListener("focus", probe);
    document.addEventListener("visibilitychange", onVisible);
    return () => {
      window.removeEventListener("focus", probe);
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, []);
  return signedIn;
}
