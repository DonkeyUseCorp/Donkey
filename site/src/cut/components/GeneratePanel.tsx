"use client";

import { useState } from "react";
import { Film, Image as ImageIcon, Loader2, Plus, Sparkles, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { signInUrl, useGenerate, useSignedIn, type GenerateJob } from "@/cut/lib/generate";
import { useEditor } from "@/cut/lib/store";
import { useLocalPref } from "@/cut/lib/uiState";
import { cn } from "@/lib/utils";

type Kind = "image" | "video";

const chip = (active: boolean) =>
  cn(
    "rounded-full border px-2.5 py-1 text-[11px] font-medium transition-colors",
    active
      ? "border-primary bg-primary/10 text-primary"
      : "border-border text-muted-foreground hover:text-foreground"
  );

export function GenerateImagePanel({ projectId }: { projectId: string }) {
  return <GeneratePanel projectId={projectId} kind="image" />;
}

export function GenerateVideoPanel({ projectId }: { projectId: string }) {
  return <GeneratePanel projectId={projectId} kind="video" />;
}

function GeneratePanel({ projectId, kind }: { projectId: string; kind: Kind }) {
  const signedIn = useSignedIn();
  const allJobs = useGenerate((s) => s.jobs);
  const jobs = allJobs.filter((j) => j.projectId === projectId && j.kind === kind);
  const [prompt, setPrompt] = useState("");
  const [tier, setTier] = useLocalPref<"fast" | "high">(
    "cut-gen-tier",
    "fast",
    (v) => v === "fast" || v === "high"
  );
  const [seconds, setSeconds] = useLocalPref<number>(
    "cut-gen-seconds",
    8,
    (v) => v === 4 || v === 6 || v === 8
  );

  const go = () => {
    const p = prompt.trim();
    if (!p) return;
    if (kind === "image") void useGenerate.getState().generateImage(projectId, p);
    else void useGenerate.getState().generateVideo(projectId, p, { tier, durationSeconds: seconds });
    setPrompt("");
  };

  return (
    <>
      <div className="flex h-12 shrink-0 items-center justify-between pr-2.5 pl-4">
        <span className="text-sm font-semibold tracking-tight">
          {kind === "image" ? "Image" : "Video"}
        </span>
      </div>

      <div className="flex min-h-0 flex-1 flex-col gap-3 overflow-y-auto px-3.5 pb-4">
        <textarea
          className="gen-prompt min-h-[88px] w-full shrink-0 resize-y rounded-lg border border-input bg-transparent px-2.5 py-2 text-[12.5px] leading-relaxed outline-none focus:border-ring"
          placeholder={
            kind === "image"
              ? "A neon-lit street market at night, cinematic…"
              : "A drone shot rising over a foggy coastline at sunrise…"
          }
          value={prompt}
          onChange={(e) => setPrompt(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
              e.preventDefault();
              go();
            }
          }}
        />

        {kind === "video" && (
          <div className="flex shrink-0 items-center justify-between gap-2">
            <div className="flex gap-1.5">
              {[4, 6, 8].map((s) => (
                <button key={s} className={chip(seconds === s)} onClick={() => setSeconds(s)}>
                  {s}s
                </button>
              ))}
            </div>
            <div className="flex gap-1.5">
              {(["fast", "high"] as const).map((t) => (
                <button key={t} className={chip(tier === t)} onClick={() => setTier(t)}>
                  {t === "fast" ? "Fast" : "Best"}
                </button>
              ))}
            </div>
          </div>
        )}

        <Button
          className="gen-go w-full shrink-0"
          disabled={!prompt.trim() || signedIn === false}
          onClick={go}
        >
          <Sparkles data-icon="inline-start" />
          {kind === "image" ? "Generate image" : "Generate video"}
        </Button>

        {signedIn === false ? (
          <p className="gen-signin shrink-0 text-[11px] leading-relaxed text-muted-foreground">
            Generating runs on your Donkey account.{" "}
            <a className="font-medium text-blue-600 hover:underline dark:text-blue-400" href={signInUrl()}>
              Sign in
            </a>{" "}
            to continue.
          </p>
        ) : (
          <p className="shrink-0 text-[11px] leading-relaxed text-muted-foreground">
            {kind === "image"
              ? "Lands in Media as an 8s clip — trim it like footage."
              : "Veo renders take a minute or two — keep editing while it runs."}
          </p>
        )}

        {jobs.length > 0 && (
          <div className="flex flex-col gap-1.5">
            {jobs.map((j) => (
              <JobRow key={j.id} job={j} />
            ))}
          </div>
        )}
      </div>
    </>
  );
}

function JobRow({ job }: { job: GenerateJob }) {
  const asset = useEditor((s) => s.assets.find((a) => a.id === job.assetId));
  const Icon = job.kind === "image" ? ImageIcon : Film;
  return (
    <div className="gen-job group flex items-center gap-2.5 rounded-lg border border-border p-2">
      {asset ? (
        <video
          muted
          playsInline
          preload="metadata"
          src={`${asset.url}#t=0.1`}
          className="size-10 shrink-0 rounded-md bg-black object-cover"
        />
      ) : (
        <span className="grid size-10 shrink-0 place-items-center rounded-md bg-muted text-muted-foreground">
          {job.status === "running" ? (
            <Loader2 className="size-4 animate-spin" />
          ) : (
            <Icon className="size-4" />
          )}
        </span>
      )}
      <div className="min-w-0 flex-1">
        <div className="truncate text-[11.5px] font-medium">{job.prompt}</div>
        <div
          className={cn(
            "text-[10.5px] leading-snug break-words",
            job.status === "error" ? "text-red-600" : "text-muted-foreground"
          )}
        >
          {job.status === "running" &&
            (job.kind === "video" ? "Rendering with Veo…" : "Generating…")}
          {job.status === "done" && "In your media"}
          {job.status === "error" && (job.error ?? "Failed.")}
        </div>
      </div>
      {job.status === "done" && asset && (
        <button
          title="Add to timeline"
          className="grid size-6 shrink-0 place-items-center rounded-full bg-primary text-primary-foreground opacity-0 transition-opacity group-hover:opacity-100 hover:brightness-110"
          onClick={() => useEditor.getState().addClipFromAsset(asset.id)}
        >
          <Plus className="size-3.5" />
        </button>
      )}
      {job.status !== "running" && (
        <button
          title="Dismiss"
          className="grid size-6 shrink-0 place-items-center rounded-full text-muted-foreground opacity-0 transition-opacity group-hover:opacity-100 hover:text-foreground"
          onClick={() => useGenerate.getState().dismiss(job.id)}
        >
          <Trash2 className="size-3.5" />
        </button>
      )}
    </div>
  );
}
