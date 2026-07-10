"use client";

import { useEffect, useState } from "react";
import { Check, Copy, Loader2, Plus, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useLightbox } from "@/cut/lib/lightbox";
import { importImage, importStockVideo } from "@/cut/lib/media";
import { useEditor } from "@/cut/lib/store";

// The image lightbox: the bigger version of a stock or generated image, with
// its name, description, and generation prompt below, plus a button to drop it
// straight onto the timeline. Mounted once in the editor.

export function Lightbox() {
  const item = useLightbox((s) => s.item);
  const [adding, setAdding] = useState(false);
  // Keyed to the added image's src, so opening a different image clears the
  // "Added" confirmation without a reset effect.
  const [addedSrc, setAddedSrc] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);

  // Escape closes the lightbox.
  useEffect(() => {
    if (!item) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") useLightbox.getState().close();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [item]);

  if (!item) return null;

  const added = addedSrc === item.src;

  const add = async () => {
    const projectId = useEditor.getState().projectId;
    if (!projectId) return;
    setAdding(true);
    try {
      if (item.assetId) {
        useEditor.getState().addClipFromAsset(item.assetId);
      } else {
        // A stock clip imports as footage; a stock image bakes into a still.
        const asset = item.playable
          ? await importStockVideo(projectId, { url: item.src, name: item.name })
          : await importImage(projectId, { url: item.src, name: item.name });
        useEditor.getState().addClipFromAsset(asset.id);
      }
      setAddedSrc(item.src);
    } catch {
      // Leave the button enabled so the user can retry.
    } finally {
      setAdding(false);
    }
  };

  return (
    <div
      className="fixed inset-0 z-70 grid place-items-center bg-black/70 p-6 backdrop-blur-sm"
      onClick={() => useLightbox.getState().close()}
    >
      <div
        className="relative flex max-h-[92vh] w-full max-w-[860px] flex-col overflow-hidden rounded-2xl bg-card shadow-2xl"
        onClick={(e) => e.stopPropagation()}
      >
        <button
          title="Close"
          className="absolute top-3 right-3 z-10 grid size-8 place-items-center rounded-full bg-black/45 text-white hover:bg-black/65"
          onClick={() => useLightbox.getState().close()}
        >
          <X className="size-4" />
        </button>

        {item.isVideo ? (
          item.playable ? (
            <video
              controls
              autoPlay
              loop
              playsInline
              src={item.src}
              className="block max-h-[75vh] w-full bg-black object-contain"
            />
          ) : (
            <video
              muted
              playsInline
              preload="metadata"
              src={`${item.src}#t=0.1`}
              className="block max-h-[75vh] w-full object-contain"
            />
          )
        ) : (
          // eslint-disable-next-line @next/next/no-img-element -- static/project image, client-only page
          <img
            src={item.src}
            alt={item.name}
            className="block max-h-[75vh] w-full object-contain"
          />
        )}

        <div className="flex flex-col gap-3 overflow-y-auto p-4">
          <div className="flex items-center justify-between gap-3">
            <div className="min-w-0 truncate text-[15px] font-semibold tracking-tight">{item.name}</div>
            <Button className="shrink-0" disabled={adding} onClick={add}>
              {adding ? (
                <Loader2 data-icon="inline-start" className="animate-spin" />
              ) : added ? (
                <Check data-icon="inline-start" />
              ) : (
                <Plus data-icon="inline-start" />
              )}
              {added ? "Added" : "Use"}
            </Button>
          </div>

          {item.prompt && item.prompt !== item.name && (
            <div className="flex flex-col gap-1">
              <div className="flex items-center justify-between">
                <span className="text-[11px] font-semibold tracking-wider text-muted-foreground uppercase">
                  Prompt
                </span>
                <button
                  title="Copy prompt"
                  className="inline-flex items-center gap-1 rounded-md px-1.5 py-0.5 text-[10.5px] font-medium text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
                  onClick={() => {
                    void navigator.clipboard.writeText(item.prompt).then(() => {
                      setCopied(true);
                      setTimeout(() => setCopied(false), 1500);
                    });
                  }}
                >
                  {copied ? <Check className="size-3 text-emerald-600" /> : <Copy className="size-3" />}
                  {copied ? "Copied" : "Copy"}
                </button>
              </div>
              <p className="rounded-lg border border-border bg-muted/40 px-3 py-2 text-[12.5px] leading-relaxed">
                {item.prompt}
              </p>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
