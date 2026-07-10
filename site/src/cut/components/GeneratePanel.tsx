"use client";

import { useRef } from "react";
import { Copy, Film, Loader2, Maximize2, Plus, Sparkles, Trash2, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { DropdownMenuItem } from "@/components/ui/dropdown-menu";
import { clearAssetDrag, setAssetDragData } from "@/cut/lib/assetDrag";
import {
  collectRefs,
  mentionToken,
  refFromStockVideo,
  useRefCandidates,
  useAssetDrop,
} from "@/cut/lib/assetRef";
import { signInUrl, useGenerate, useSignedIn, type GenerateJob } from "@/cut/lib/generate";
import { useLightbox } from "@/cut/lib/lightbox";
import { characterPrompt, stockTitle } from "@/cut/lib/stock";
import { useEditor } from "@/cut/lib/store";
import { useLocalPref } from "@/cut/lib/uiState";
import { useVideoGen } from "@/cut/lib/videoGen";
import { cn } from "@/lib/utils";
import { MentionTextarea, RefChips, RefHandlePill } from "./AssetRefs";
import { GeneratedAssetMenu } from "./GeneratedAssetMenu";

// The generate-video panel: an always-on column in the Video tab, sitting left
// of the stock-clip browser. Clicking a stock tile loads its saved prompt here.
//
// A visual reference (dragged in or @name-mentioned) seeds the render: Veo
// takes one input image, so the first reference's picture becomes the start
// frame.

// Segmented pill group, same language as the platform switcher in PlatformPreview.
const segGroup = "flex gap-0.5 rounded-full border border-border bg-card p-0.5 shadow-xs";
const segButton = (active: boolean) =>
  cn(
    "rounded-full px-2.5 py-[3px] text-[11px] font-medium transition-colors",
    active ? "bg-foreground text-background" : "text-muted-foreground hover:text-foreground"
  );

export function GenerateVideoPanel({ projectId }: { projectId: string }) {
  const signedIn = useSignedIn();
  const allJobs = useGenerate((s) => s.jobs);
  const jobs = allJobs.filter((j) => j.projectId === projectId && j.kind === "video");
  const { prompt, refs, character } = useVideoGen();
  const candidates = useRefCandidates();
  const { active: dropActive, attachTarget, targetProps } = useAssetDrop((ref) => {
    if (ref.kind !== "audio") useVideoGen.getState().addRef(ref);
  });
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
    const { text, refs: all } = collectRefs(prompt.trim(), refs, candidates, { dropAudio: true });
    if (!text) return;
    // Character mode: the text is the spoken line — compose it with the
    // persona, and seed the render with the character's poster frame so the
    // same person delivers it.
    const composed = character?.persona ? characterPrompt(character.persona, text) : text;
    const seedRefs = character ? [refFromStockVideo(character)] : all;
    void useGenerate
      .getState()
      .generateVideo(projectId, composed, { tier, durationSeconds: seconds, refs: seedRefs });
    useVideoGen.getState().openWith("");
  };

  return (
    <>
      <div className="flex h-12 shrink-0 items-center justify-between pr-2.5 pl-4">
        <span className="text-sm font-semibold tracking-tight">Generate video</span>
      </div>

      <div
        ref={attachTarget}
        {...targetProps}
        className="relative flex min-h-0 flex-1 flex-col gap-3 overflow-y-auto px-3.5 pb-4"
      >
        {/* Composer: the character and attached references ride inside the
            input box, above the prompt — same shape as the image panel, which
            also highlights this box while a drag hovers the panel. */}
        <div
          className={cn(
            "flex shrink-0 flex-col rounded-lg border border-input focus-within:border-ring",
            dropActive && "border-[#0a84ff] ring-2 ring-[#0a84ff]/30 ring-inset"
          )}
        >
          {character && (
            <div className="gen-character flex items-center gap-2 p-2 pb-0">
              {/* eslint-disable-next-line @next/next/no-img-element -- bundled static thumb on a client-only page */}
              <img
                src={character.thumb}
                alt={stockTitle(character.id)}
                className="size-8 shrink-0 rounded-md object-cover"
              />
              <span className="min-w-0 flex-1 truncate text-[12px] font-medium">
                {stockTitle(character.id)}
              </span>
              <button
                title="Leave character mode"
                className="grid size-6 shrink-0 place-items-center rounded-full text-muted-foreground hover:text-foreground"
                onClick={() => useVideoGen.getState().clearCharacter()}
              >
                <X className="size-3.5" />
              </button>
            </div>
          )}
          <RefChips
            refs={refs}
            onRemove={(ref) => useVideoGen.getState().removeRef(ref)}
            className="p-2 pb-0"
            peekSide="bottom"
          />
          <MentionTextarea
            className="gen-prompt min-h-[88px] w-full resize-y bg-transparent px-2.5 py-2 text-[12.5px] leading-relaxed outline-none"
            placeholder={
              character
                ? "What should they say?"
                : "A drone shot rising over a foggy coastline at sunrise… Drop media in or type @ to reference it."
            }
            value={prompt}
            onChange={(v) => useVideoGen.getState().setPrompt(v)}
            candidates={candidates}
            submitKey="mod-enter"
            menuSide="bottom"
            onSubmit={go}
          />
        </div>

        <div className="flex shrink-0 items-center justify-between gap-2">
          <div className={segGroup}>
            {[4, 6, 8].map((s) => (
              <button
                key={s}
                className={segButton(seconds === s)}
                aria-pressed={seconds === s}
                onClick={() => setSeconds(s)}
              >
                {s}s
              </button>
            ))}
          </div>
          <div className={segGroup}>
            {(["fast", "high"] as const).map((t) => (
              <button
                key={t}
                className={segButton(tier === t)}
                aria-pressed={tier === t}
                onClick={() => setTier(t)}
              >
                {t === "fast" ? "Fast" : "Best"}
              </button>
            ))}
          </div>
        </div>

        <Button
          className="gen-go w-full shrink-0"
          disabled={!prompt.trim() || signedIn === false}
          onClick={go}
        >
          <Sparkles data-icon="inline-start" />
          Generate video
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
            Renders take a minute or two. Keep editing while it runs.
          </p>
        )}

        {jobs.length > 0 && (
          <div className="flex flex-col gap-1.5">
            {jobs.map((j) => (
              <JobRow
                key={j.id}
                job={j}
                handle={
                  candidates.find((c) => c.scope === "project" && c.id === j.assetId)?.handle
                }
              />
            ))}
          </div>
        )}
      </div>
    </>
  );
}

/** A finished render is a full-width tile mirroring the image panel's
 * generated tiles: hover plays it (with sound), the prompt rides a bottom
 * gradient, and the actions overlay the corners. In-flight and failed jobs
 * stay a compact status row. */
function JobRow({ job, handle }: { job: GenerateJob; handle?: string }) {
  const asset = useEditor((s) => s.assets.find((a) => a.id === job.assetId));
  const tileRef = useRef<HTMLDivElement>(null);
  const videoRef = useRef<HTMLVideoElement>(null);

  if (job.status !== "done" || !asset) {
    return (
      <div className="gen-job group flex items-center gap-2.5 rounded-lg border border-border p-2">
        <span className="grid size-10 shrink-0 place-items-center rounded-md bg-muted text-muted-foreground">
          {job.status === "running" ? (
            <Loader2 className="size-4 animate-spin" />
          ) : (
            <Film className="size-4" />
          )}
        </span>
        <div className="min-w-0 flex-1">
          <div className="truncate text-[11.5px] font-medium">{job.prompt}</div>
          <div
            className={cn(
              "text-[10.5px] leading-snug break-words",
              job.status === "error" ? "text-red-600" : "text-muted-foreground"
            )}
          >
            {job.status === "running" ? "Rendering…" : (job.error ?? "Failed.")}
          </div>
        </div>
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

  return (
    <div
      ref={tileRef}
      className="gen-job group relative overflow-hidden rounded-lg"
      onMouseEnter={() => {
        const v = videoRef.current;
        if (!v) return;
        // Preview with sound; if the browser blocks unmuted autoplay, fall
        // back to a silent preview.
        v.muted = false;
        void v.play().catch(() => {
          v.muted = true;
          void v.play().catch(() => {});
        });
      }}
      onMouseLeave={() => {
        const v = videoRef.current;
        if (v) {
          v.pause();
          v.currentTime = 0.1;
          v.muted = true;
        }
      }}
    >
      <button
        className="block w-full outline-none focus-visible:ring-2 focus-visible:ring-ring"
        draggable
        onDragStart={(e) => {
          setAssetDragData(e, asset.id);
          // Drag the rounded tile itself so the ghost keeps the video's corner
          // radius instead of the browser's square, white-framed default.
          if (tileRef.current) {
            const r = tileRef.current.getBoundingClientRect();
            e.dataTransfer.setDragImage(tileRef.current, e.clientX - r.left, e.clientY - r.top);
          }
        }}
        onDragEnd={clearAssetDrag}
        onClick={() => useVideoGen.getState().openWith(job.prompt)}
      >
        <video
          ref={videoRef}
          muted
          loop
          playsInline
          preload="metadata"
          src={`${asset.url}#t=0.1`}
          className="aspect-[16/10] w-full bg-black object-cover"
        />
      </button>
      {handle && (
        <RefHandlePill
          token={`@${handle}`}
          className="absolute top-1 left-1 opacity-0 transition-opacity group-hover:opacity-100"
        />
      )}
      <div className="pointer-events-none absolute inset-x-0 bottom-0 bg-gradient-to-t from-black/70 to-transparent px-2 py-1.5 opacity-0 transition-opacity group-hover:opacity-100">
        <span className="block truncate text-[11px] font-medium text-white">{job.prompt}</span>
      </div>
      <div className="absolute top-1 right-1 flex gap-1">
        <button
          title="Add to timeline"
          className="grid size-5 place-items-center rounded-full bg-primary text-primary-foreground opacity-0 transition-opacity group-hover:opacity-100 hover:brightness-110"
          onClick={() => useEditor.getState().addClipFromAsset(asset.id)}
        >
          <Plus className="size-3" />
        </button>
        <GeneratedAssetMenu
          asset={asset}
          projectId={job.projectId}
          triggerClassName="grid size-5 place-items-center rounded-full bg-black/45 text-white opacity-0 transition-opacity group-hover:opacity-100 data-popup-open:opacity-100 hover:bg-black/65"
          before={
            <>
              <DropdownMenuItem
                onClick={() =>
                  useLightbox.getState().open({
                    src: asset.url,
                    isVideo: true,
                    playable: true,
                    name: asset.name,
                    prompt: job.prompt,
                    assetId: asset.id,
                  })
                }
              >
                <Maximize2 /> Expand
              </DropdownMenuItem>
              <DropdownMenuItem
                onClick={() =>
                  void navigator.clipboard
                    .writeText(handle ? `@${handle}` : mentionToken(asset.name))
                    .catch(() => {})
                }
              >
                <Copy /> Copy reference
              </DropdownMenuItem>
            </>
          }
          after={
            <DropdownMenuItem onClick={() => useGenerate.getState().dismiss(job.id)}>
              <Trash2 /> Dismiss
            </DropdownMenuItem>
          }
        />
      </div>
    </div>
  );
}
