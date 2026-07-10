"use client";

import { useEffect, useMemo, useRef } from "react";
import { ChevronDown, Loader2, Maximize2, Sparkles, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { clearAssetDrag, setAssetDragData } from "@/cut/lib/assetDrag";
import { collectRefs, useRefCandidates, useAssetDrop } from "@/cut/lib/assetRef";
import { signInUrl, useGenerate, useSignedIn } from "@/cut/lib/generate";
import { IMAGE_ASPECT_LABEL, useImageGen, type ImageAspect } from "@/cut/lib/imageGen";
import { useLightbox } from "@/cut/lib/lightbox";
import { useEditor } from "@/cut/lib/store";
import type { MediaAsset } from "@/cut/lib/types";
import { cn } from "@/lib/utils";
import { CopyRefButton, MentionTextarea, RefChips, RefHandlePill } from "./AssetRefs";

// The generate-image panel: an always-on column in the Image tab, sitting left
// of the stock browser. Clicking a stock tile loads its saved prompt here; the
// user picks a size, edits the prompt, generates on their Donkey account, and
// the results stack below as big tiles.
//
// References ride along as input images: drag any image or video in (stock
// tile, media card, library clip, timeline clip) or mention it by @name.

export function ImageGenPanel({ projectId }: { projectId: string }) {
  const { prompt, aspect, refs } = useImageGen();
  const signedIn = useSignedIn();
  const candidates = useRefCandidates();
  const job = useGenerate((s) =>
    s.jobs.find((j) => j.kind === "image" && j.projectId === projectId)
  );
  // Select the stable `assets` reference and derive here: filtering inside the
  // selector returns a fresh array every store write (including usePlayback's
  // per-frame ticks) and would re-render the panel constantly. Newest first.
  const assets = useEditor((s) => s.assets);
  const generated = useMemo(
    () => assets.filter((a) => a.origin === "generated" && a.type === "image").reverse(),
    [assets]
  );
  const { active: dropActive, attachTarget, targetProps } = useAssetDrop((ref) => {
    if (ref.kind !== "audio") useImageGen.getState().addRef(ref);
  });

  // Default the size to the project's own orientation when the panel opens, so
  // a widescreen project generates landscape images by default (the user can
  // still pick another size). 1:1 has no project counterpart.
  useEffect(() => {
    useImageGen.getState().setAspect(useEditor.getState().aspect);
  }, []);

  const go = () => {
    const { text, refs: all } = collectRefs(prompt.trim(), refs, candidates, { dropAudio: true });
    if (!text) return;
    void useGenerate.getState().generateImage(projectId, text, { refs: all, aspect });
  };

  return (
    <div ref={attachTarget} {...targetProps} className="relative flex min-h-0 flex-1 flex-col">
      <div className="flex h-12 shrink-0 items-center pr-2.5 pl-4">
        <span className="text-sm font-semibold tracking-tight">Generate image</span>
      </div>

      <div className="flex min-h-0 flex-1 flex-col gap-3 overflow-y-auto px-3.5 pb-4">
        {/* Composer: attached references ride as little image thumbnails inside
            the input box, above the prompt (Claude-style). */}
        <div
          className={cn(
            "flex shrink-0 flex-col rounded-lg border border-input focus-within:border-ring",
            dropActive && "border-[#0a84ff] ring-2 ring-[#0a84ff]/30 ring-inset"
          )}
        >
          <RefChips
            refs={refs}
            onRemove={(r) => useImageGen.getState().removeRef(r)}
            className="p-2 pb-0"
            peekSide="bottom"
          />
          <MentionTextarea
            className="min-h-[100px] w-full resize-y bg-transparent px-2.5 py-2 text-[12.5px] leading-relaxed outline-none"
            placeholder="A neon-lit street market at night, cinematic… Drop an image in or type @ to reference one."
            value={prompt}
            onChange={(v) => useImageGen.getState().setPrompt(v)}
            candidates={candidates}
            submitKey="mod-enter"
            menuSide="bottom"
            onSubmit={go}
          />
        </div>

        <DropdownMenu>
          <DropdownMenuTrigger className="flex w-full shrink-0 items-center justify-between rounded-lg border border-input px-2.5 py-2 text-[12.5px] outline-none hover:border-ring focus-visible:border-ring">
            <span className="text-muted-foreground">Size</span>
            <span className="flex items-center gap-1 font-medium">
              {IMAGE_ASPECT_LABEL[aspect]}
              <ChevronDown className="size-3.5 text-muted-foreground" />
            </span>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="start" className="min-w-[190px]">
            <DropdownMenuRadioGroup
              value={aspect}
              onValueChange={(v) => useImageGen.getState().setAspect(v as ImageAspect)}
            >
              {(Object.keys(IMAGE_ASPECT_LABEL) as ImageAspect[]).map((a) => (
                <DropdownMenuRadioItem key={a} value={a} className="whitespace-nowrap">
                  {IMAGE_ASPECT_LABEL[a]}
                </DropdownMenuRadioItem>
              ))}
            </DropdownMenuRadioGroup>
          </DropdownMenuContent>
        </DropdownMenu>

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

        {signedIn === false && (
          <p className="shrink-0 text-[11px] leading-relaxed text-muted-foreground">
            Generating runs on your Donkey account.{" "}
            <a className="font-medium text-blue-600 hover:underline dark:text-blue-400" href={signInUrl()}>
              Sign in
            </a>{" "}
            to continue.
          </p>
        )}

        {/* A generation in flight (or a failed one): the finished asset drops
            into the list below, so only surface the transient states here. */}
        {job && job.status !== "done" && (
          <div className="flex shrink-0 items-center gap-2">
            {job.status === "running" && (
              <Loader2 className="size-3.5 shrink-0 animate-spin text-muted-foreground" />
            )}
            <div className="min-w-0 flex-1">
              <div className="truncate text-[11.5px] font-medium">{job.prompt}</div>
              <div
                className={cn(
                  "text-[10.5px] leading-snug break-words",
                  job.status === "error" ? "text-red-600" : "text-muted-foreground"
                )}
              >
                {job.status === "running" ? "Generating…" : (job.error ?? "Failed.")}
              </div>
            </div>
          </div>
        )}

        {generated.length > 0 && (
          <div className="flex shrink-0 flex-col gap-1.5">
            <span className="text-[11px] font-semibold text-muted-foreground">Generated</span>
            {generated.map((a) => (
              <GeneratedTile
                key={a.id}
                asset={a}
                handle={candidates.find((c) => c.scope === "project" && c.id === a.id)?.handle}
              />
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

/** A generated image, shown big: reference it in a prompt by its @handle, drag
 * it onto the timeline or into chat, click to reload its prompt, copy its
 * @reference, or delete it. Its name surfaces on hover so the grid stays clean. */
function GeneratedTile({ asset, handle }: { asset: MediaAsset; handle?: string }) {
  const tileRef = useRef<HTMLDivElement>(null);
  return (
    <div ref={tileRef} className="group relative overflow-hidden rounded-lg">
      <button
        className="block w-full outline-none focus-visible:ring-2 focus-visible:ring-ring"
        title={asset.name}
        draggable
        onDragStart={(e) => {
          setAssetDragData(e, asset.id);
          // Drag the rounded tile itself so the ghost keeps the image's corner
          // radius instead of the browser's square, white-framed default.
          if (tileRef.current) {
            const r = tileRef.current.getBoundingClientRect();
            e.dataTransfer.setDragImage(
              tileRef.current,
              e.clientX - r.left,
              e.clientY - r.top
            );
          }
        }}
        onDragEnd={clearAssetDrag}
        onClick={() => useImageGen.getState().openWith(asset.name)}
      >
        {/* eslint-disable-next-line @next/next/no-img-element -- engine media file, not Next-optimizable */}
        <img
          src={asset.url}
          alt={asset.name}
          loading="lazy"
          className="aspect-[16/10] w-full bg-black object-cover transition-transform group-hover:scale-[1.04]"
        />
      </button>
      {handle && (
        <RefHandlePill
          token={`@${handle}`}
          className="absolute top-1 left-1 opacity-0 transition-opacity group-hover:opacity-100"
        />
      )}
      <div className="pointer-events-none absolute inset-x-0 bottom-0 bg-gradient-to-t from-black/70 to-transparent px-2 py-1.5 opacity-0 transition-opacity group-hover:opacity-100">
        <span className="block truncate text-[11px] font-medium text-white">{asset.name}</span>
      </div>
      <div className="absolute top-1 right-1 flex gap-1 opacity-0 transition-opacity group-hover:opacity-100">
        <button
          title="Expand"
          className="grid size-5 place-items-center rounded-full bg-black/45 text-white hover:bg-black/65"
          onClick={() =>
            useLightbox.getState().open({
              src: asset.url,
              isVideo: false,
              name: asset.name,
              prompt: asset.name,
              assetId: asset.id,
            })
          }
        >
          <Maximize2 className="size-3" />
        </button>
        <CopyRefButton name={asset.name} />
        <button
          title="Delete"
          className="grid size-5 place-items-center rounded-full bg-black/45 text-white hover:bg-black/65"
          onClick={() => useEditor.getState().removeAsset(asset.id)}
        >
          <Trash2 className="size-3" />
        </button>
      </div>
    </div>
  );
}
