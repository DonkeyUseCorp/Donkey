"use client";

import { useEffect } from "react";
import { create } from "zustand";
import { apiFetch, apiJson } from "./api";
import type { AssetRef } from "./assetRef";
import { composeGenPrompt, foldTextRefs } from "./composeGen";
import { hostedPost } from "./hosted";
import { enrichAsset, importFileToProject } from "./media";
import { refsToInlineImages, visualRefs, type InlineImage } from "./refMedia";
import { useImageGen } from "./imageGen";
import { useEditor } from "./store";
import { mediaUrl, type MediaAsset } from "./types";

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
  status: "running" | "done" | "error";
  error?: string;
  /** The project asset the finished generation landed as. */
  assetId?: string;
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
}

export interface VideoGenOptions {
  tier?: "fast" | "high";
  durationSeconds?: number;
  /** Composition shape; defaults to the project's orientation. */
  aspect?: "16:9" | "9:16";
  resolution?: "720p" | "1080p";
  /** References of any kind — video, image, text file. Veo takes one
   * input image, so at most one picture seeds the render. */
  refs?: AssetRef[];
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

function bytesFromBase64(b64: string): Uint8Array<ArrayBuffer> {
  const bin = atob(b64);
  const bytes = new Uint8Array(new ArrayBuffer(bin.length));
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

/** Settled video jobs persist per browser, so a render left unplaced (a chat
 * card, the Video panel's renders list) survives a reload. Running jobs don't
 * persist: a reload kills the in-flight poll loop, so a restored one would
 * spin forever. */
const JOBS_KEY = "cut-gen-video-jobs";
const JOBS_CAP = 50;

function readPersistedJobs(): GenerateJob[] {
  try {
    const v = JSON.parse(localStorage.getItem(JOBS_KEY) ?? "[]") as unknown;
    return Array.isArray(v)
      ? (v as GenerateJob[]).filter((j) => j?.id && j.status !== "running")
      : [];
  } catch {
    return [];
  }
}

function persistJobs(jobs: GenerateJob[]) {
  try {
    localStorage.setItem(
      JOBS_KEY,
      JSON.stringify(
        jobs.filter((j) => j.kind === "video" && j.status !== "running").slice(0, JOBS_CAP)
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

  // The media file exists either way; only the open project can record it.
  // Returns whether it was adopted (false when the user switched projects).
  const adopt = (projectId: string, asset: MediaAsset): boolean => {
    if (useEditor.getState().projectId !== projectId) return false;
    useEditor.getState().addAsset(asset);
    void enrichAsset(asset);
    return true;
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
      const job: GenerateJob = { id: uid(), projectId, kind: "image", prompt, status: "running" };
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
          adopt(projectId, asset);
          update(job.id, { status: "done", assetId: asset.id });
        } catch (err) {
          fail(job.id, err);
        }
        return settled(job.id, job);
      })();
    },

    generateVideo: (projectId, prompt, opts) => {
      const job: GenerateJob = { id: uid(), projectId, kind: "video", prompt, status: "running" };
      set((s) => ({ jobs: [job, ...s.jobs] }));
      const settledRun = (async () => {
        try {
          // The job (and the landed asset's name) keeps the user's own words;
          // only the render sees the composed prompt. Veo seeds from a single
          // first-frame image, so at most one kept picture rides along.
          const { prompt: sent, images } = await promptAndImages(
            "video",
            prompt,
            opts?.refs ?? [],
            opts?.composeRefs !== false,
            1
          );
          const res = await hostedPost("/api/inference/assets", {
            kind: "video",
            prompt: sent,
            ...(images.length > 0 ? { inputs: { images } } : {}),
            parameters: {
              tier: opts?.tier === "high" ? "high" : "fast",
              aspectRatio: opts?.aspect ?? useEditor.getState().aspect,
              ...(opts?.resolution ? { resolution: opts.resolution } : {}),
              ...(opts?.durationSeconds ? { durationSeconds: opts.durationSeconds } : {}),
            },
          });
          if (!res.ok) throw new Error(await readError(res, "Video generation failed."));
          let gen = (await res.json()) as GenerationResponse;

          const deadline = Date.now() + VIDEO_DEADLINE_MS;
          while (gen.status === "in_progress") {
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
          const fileName = `ai-${promptSlug(prompt)}.mp4`;
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

          const asset = await importFileToProject(projectId, file);
          if (!asset) throw new Error("Could not import the generated video.");
          asset.name = promptName(prompt);
          asset.origin = "generated"; // lives in the generate panel, not Media
          if (adopt(projectId, asset)) opts?.onDone?.(asset);
          update(job.id, { status: "done", assetId: asset.id });
        } catch (err) {
          fail(job.id, err);
        }
        return settled(job.id, job);
      })();
      return { jobId: job.id, settled: settledRun };
    },

    dismiss: (id) => {
      set((s) => ({ jobs: s.jobs.filter((j) => j.id !== id) }));
      persistJobs(get().jobs);
    },
  };
});

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
