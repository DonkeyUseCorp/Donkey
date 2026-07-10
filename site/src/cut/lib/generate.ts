"use client";

import { useEffect } from "react";
import { create } from "zustand";
import { apiFetch, apiJson } from "./api";
import type { AssetRef } from "./assetRef";
import { enrichAsset, importFileToProject } from "./media";
import { refsToInlineImages } from "./refMedia";
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
   * `refs` are visual references — each uploads as an input image (a stock
   * image as-is, a video by a captured poster frame). */
  generateImage: (
    projectId: string,
    prompt: string,
    opts?: { refs?: AssetRef[]; aspect?: "16:9" | "9:16" | "1:1" }
  ) => Promise<GenerateJob>;
  generateVideo: (
    projectId: string,
    prompt: string,
    opts?: {
      tier?: "fast" | "high";
      durationSeconds?: number;
      /** Visual references; Veo takes one input image, so the first ref's
       * picture seeds the render. */
      refs?: AssetRef[];
      /** Called once with the landed asset when the render completes and the
       * project is still open — lets the AI place the clip after a background
       * render it couldn't wait out (the assistant tool bridge caps at 2min). */
      onDone?: (asset: MediaAsset) => void;
    }
  ) => Promise<GenerateJob>;
  dismiss: (id: string) => void;
}

const CLIENT_ID = "donkey-cut";
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

/** POST one of Donkey's hosted inference routes with the user's session. */
export const hostedPost = (path: string, body: unknown, signal?: AbortSignal) =>
  fetch(path, {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-donkey-client-id": CLIENT_ID },
    body: JSON.stringify(body),
    signal,
  });

async function readError(res: Response, fallback: string): Promise<string> {
  if (res.status === 401) return "Sign in to Donkey to generate media.";
  const body = (await res.json().catch(() => null)) as {
    error?: unknown;
    message?: unknown;
  } | null;
  const message = [body?.message, body?.error].find(
    (v): v is string => typeof v === "string" && v.length > 0
  );
  if (res.status === 402) return message ?? "Not enough Donkey credits — top up to generate.";
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

function bytesFromBase64(b64: string): Uint8Array<ArrayBuffer> {
  const bin = atob(b64);
  const bytes = new Uint8Array(new ArrayBuffer(bin.length));
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

export const useGenerate = create<GenerateState>((set, get) => {
  // A single session probe is in flight at a time, but the answer stays
  // re-checkable for the page's whole life: a sign-in can complete in another
  // tab, or the session cookie can land a beat after this page loads.
  let probing: Promise<boolean> | null = null;

  const update = (id: string, patch: Partial<GenerateJob>) =>
    set((s) => ({ jobs: s.jobs.map((j) => (j.id === id ? { ...j, ...patch } : j)) }));

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
    jobs: [],

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
          const frame =
            aspect === "16:9" ? "16:9 widescreen" : aspect === "1:1" ? "1:1 square" : "9:16 vertical";
          const images = await refsToInlineImages(opts?.refs ?? []);
          const res = await hostedPost("/api/inference/assets", {
            kind: "image",
            // The image route takes no aspect parameter; steer it in the prompt.
            prompt: `${prompt}\n\nCompose the image in a ${frame} frame.`,
            ...(images.length > 0 ? { inputs: { images } } : {}),
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
      return (async () => {
        try {
          // Veo seeds from a single first-frame image; extra refs would be dropped
          // silently, so send just the first.
          const images = await refsToInlineImages((opts?.refs ?? []).slice(0, 1));
          const res = await hostedPost("/api/inference/assets", {
            kind: "video",
            prompt,
            ...(images.length > 0 ? { inputs: { images } } : {}),
            parameters: {
              tier: opts?.tier === "high" ? "high" : "fast",
              aspectRatio: useEditor.getState().aspect,
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
    },

    dismiss: (id) => set((s) => ({ jobs: s.jobs.filter((j) => j.id !== id) })),
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
