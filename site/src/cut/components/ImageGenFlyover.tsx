"use client";

import { Loader2, Plus, Sparkles, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { collectRefs, useRefCandidates, useAssetDrop } from "@/cut/lib/assetRef";
import { signInUrl, useGenerate, useSignedIn } from "@/cut/lib/generate";
import { useImageGen } from "@/cut/lib/imageGen";
import { useEditor } from "@/cut/lib/store";
import { cn } from "@/lib/utils";
import { MentionTextarea, RefChips } from "./AssetRefs";

// The generate-image flyover: slides over the right edge of the preview canvas
// (covering it is fine — the render is the thing being looked at). Opens from
// the stock browser with a stock image's saved prompt, or blank; the user edits
// the prompt, generates on their Donkey account, and the result shows here
// while also landing in Media and the browser's Generated category.
//
// References ride along as input images: drag any image or video in (stock
// tile, media card, library clip, timeline clip) or mention it by @name.

export function ImageGenFlyover({ projectId }: { projectId: string }) {
  const { open, prompt, refs } = useImageGen();
  const signedIn = useSignedIn();
  const candidates = useRefCandidates();
  const job = useGenerate((s) =>
    s.jobs.find((j) => j.kind === "image" && j.projectId === projectId)
  );
  const asset = useEditor((s) =>
    job?.assetId ? s.assets.find((a) => a.id === job.assetId) : undefined
  );
  const { active: dropActive, attachTarget, targetProps } = useAssetDrop((ref) => {
    if (ref.kind !== "audio") useImageGen.getState().addRef(ref);
  });

  if (!open) return null;

  const go = () => {
    const { text, refs: all } = collectRefs(prompt.trim(), refs, candidates, { dropAudio: true });
    if (!text) return;
    void useGenerate.getState().generateImage(projectId, text, { refs: all });
  };

  return (
    <aside
      ref={attachTarget}
      {...targetProps}
      className="absolute inset-y-0 right-0 z-40 flex w-[320px] flex-col border-l border-border bg-card shadow-[-12px_0_32px_rgba(0,0,0,0.12)]"
    >
      {dropActive && (
        <div className="pointer-events-none absolute inset-1.5 z-10 grid place-items-center rounded-xl border-2 border-dashed border-[#0a84ff] bg-[#0a84ff]/8">
          <span className="rounded-full bg-card px-3 py-1 text-[11.5px] font-medium text-[#0a84ff] shadow-sm">
            Drop to use as reference
          </span>
        </div>
      )}
      <div className="flex h-12 shrink-0 items-center justify-between border-b border-border pr-2.5 pl-4">
        <span className="text-sm font-semibold tracking-tight">Generate image</span>
        <button
          title="Close"
          className="grid size-7 place-items-center rounded-md text-muted-foreground hover:text-foreground"
          onClick={() => useImageGen.getState().close()}
        >
          <X className="size-4" />
        </button>
      </div>

      <div className="flex min-h-0 flex-1 flex-col gap-3 overflow-y-auto p-3.5">
        <RefChips
          refs={refs}
          onRemove={(r) => useImageGen.getState().removeRef(r)}
          className="shrink-0"
          peekSide="bottom"
        />
        <MentionTextarea
          className="min-h-[110px] w-full shrink-0 resize-y rounded-lg border border-input bg-transparent px-2.5 py-2 text-[12.5px] leading-relaxed outline-none focus:border-ring"
          placeholder="A neon-lit street market at night, cinematic… Drop an image in or type @ to reference one."
          value={prompt}
          onChange={(v) => useImageGen.getState().setPrompt(v)}
          candidates={candidates}
          submitKey="mod-enter"
          menuSide="bottom"
          onSubmit={go}
        />

        <Button
          className="w-full shrink-0"
          disabled={!prompt.trim() || signedIn === false || job?.status === "running"}
          onClick={go}
        >
          {job?.status === "running" ? (
            <Loader2 data-icon="inline-start" className="animate-spin" />
          ) : (
            <Sparkles data-icon="inline-start" />
          )}
          Generate image
        </Button>

        {signedIn === false ? (
          <p className="shrink-0 text-[11px] leading-relaxed text-muted-foreground">
            Generating runs on your Donkey account.{" "}
            <a className="font-medium text-blue-600 hover:underline dark:text-blue-400" href={signInUrl()}>
              Sign in
            </a>{" "}
            to continue.
          </p>
        ) : (
          <p className="shrink-0 text-[11px] leading-relaxed text-muted-foreground">
            Lands in Media and under Generated in the stock browser.
          </p>
        )}

        {job && (
          <div className="flex shrink-0 flex-col gap-2">
            {job.status === "done" && asset && (
              <video
                muted
                playsInline
                preload="metadata"
                src={`${asset.url}#t=0.1`}
                className="w-full rounded-lg bg-black"
              />
            )}
            <div className="flex items-start gap-2">
              <div className="min-w-0 flex-1">
                <div className="truncate text-[11.5px] font-medium">{job.prompt}</div>
                <div
                  className={cn(
                    "text-[10.5px] leading-snug break-words",
                    job.status === "error" ? "text-red-600" : "text-muted-foreground"
                  )}
                >
                  {job.status === "running" && "Generating…"}
                  {job.status === "done" && "In your media"}
                  {job.status === "error" && (job.error ?? "Failed.")}
                </div>
              </div>
              {job.status === "done" && asset && (
                <button
                  title="Add to timeline"
                  className="grid size-6 shrink-0 place-items-center rounded-full bg-primary text-primary-foreground hover:brightness-110"
                  onClick={() => useEditor.getState().addClipFromAsset(asset.id)}
                >
                  <Plus className="size-3.5" />
                </button>
              )}
            </div>
          </div>
        )}
      </div>
    </aside>
  );
}
