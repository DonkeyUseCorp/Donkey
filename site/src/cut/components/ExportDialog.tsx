"use client";

import { useMemo, useState } from "react";
import { Check } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { useElapsed } from "@/cut/hooks/useElapsed";
import { EXPORT_PRESETS, originalSettings, presetSettings } from "@/cut/lib/exportClient";
import { useExport } from "@/cut/lib/exportStore";
import { useEditor } from "@/cut/lib/store";
import { cn } from "@/lib/utils";

export function ExportDialog() {
  const setExportOpen = useEditor((s) => s.setExportOpen);
  const aspect = useEditor((s) => s.aspect);
  const clips = useEditor((s) => s.clips);
  const assets = useEditor((s) => s.assets);
  const status = useExport((s) => s.status);
  const ratio = useExport((s) => s.ratio);
  const startedAt = useExport((s) => s.startedAt);
  const elapsed = useElapsed(status === "running" ? startedAt : null);
  const error = useExport((s) => s.error);
  // "Original" leads: sized from the footage on the timeline, so it is always
  // the highest option. The fixed presets follow, flipped to the aspect.
  const presets = useMemo(
    () => [
      {
        id: "original",
        label: "Original · matches source",
        detail: "H.264 · best quality",
        settings: originalSettings(aspect, clips, assets),
      },
      ...EXPORT_PRESETS.map((p) => ({
        id: p.id,
        label: p.label,
        detail: p.detail,
        settings: presetSettings(p, aspect),
      })),
    ],
    [aspect, clips, assets]
  );
  const [presetId, setPresetId] = useState("original");

  // Closing never cancels a running render — clicking outside (or Esc) just
  // dismisses the dialog and the render keeps going in the background, tracked
  // by the status chip. Only Cancel stops it. A finished/failed export is
  // cleared on close.
  const close = () => {
    if (useExport.getState().status !== "running") useExport.getState().dismiss();
    setExportOpen(false);
  };

  const run = () => {
    const s = useEditor.getState();
    if (!s.projectId) return;
    const settings = (presets.find((p) => p.id === presetId) ?? presets[0]).settings;
    useExport.getState().start(s.projectId, {
      assets: s.assets,
      clips: s.clips,
      audioClips: s.audioClips,
      overlays: s.overlays,
      subtitles: s.subtitles,
      fadeIn: s.fadeIn,
      fadeOut: s.fadeOut,
    }, settings);
  };

  return (
    <Dialog open onOpenChange={(o) => !o && close()}>
      <DialogContent className="sm:max-w-sm">
        <DialogHeader>
          <DialogTitle>Export</DialogTitle>
        </DialogHeader>

        {status === "idle" && (
          <>
            <div className="flex flex-col gap-2" role="radiogroup" aria-label="Export preset">
              {presets.map((p) => (
                <button
                  key={p.id}
                  role="radio"
                  aria-checked={presetId === p.id}
                  className={cn(
                    "flex flex-col items-start rounded-lg border border-border bg-background px-3 py-2.5 text-left transition-colors hover:border-input",
                    presetId === p.id && "border-primary bg-primary/10"
                  )}
                  onClick={() => setPresetId(p.id)}
                >
                  <span className="text-sm font-medium">{p.label}</span>
                  <span className="text-xs text-muted-foreground">
                    {p.settings.width} × {p.settings.height} · {p.detail}
                  </span>
                </button>
              ))}
            </div>
            <DialogFooter>
              <Button className="w-full" onClick={run}>
                Export video
              </Button>
            </DialogFooter>
          </>
        )}

        {status === "running" && (
          <>
            <div className="pt-1">
              <div className="h-1.5 overflow-hidden rounded-full bg-secondary">
                <div
                  className="h-full rounded-full bg-primary transition-[width] duration-300"
                  style={{ width: `${Math.round(ratio * 100)}%` }}
                />
              </div>
              <div className="mt-2.5 flex justify-end text-xs text-muted-foreground">
                <span className="font-mono tabular-nums">
                  {Math.round(ratio * 100)}%{elapsed ? ` · ${elapsed}` : ""}
                </span>
              </div>
              <p className="mt-3 text-center text-xs text-muted-foreground">
                Rendering in the background. You can keep editing, or close this
                to hide it and it keeps going.
              </p>
            </div>
            <DialogFooter className="py-2 sm:justify-center">
              <Button
                variant="ghost"
                size="sm"
                className="text-xs text-muted-foreground"
                onClick={() => {
                  useExport.getState().cancel();
                  setExportOpen(false);
                }}
              >
                Cancel export
              </Button>
            </DialogFooter>
          </>
        )}

        {status === "done" && (
          <>
            <div className="flex flex-col items-center pt-2 text-center">
              <span className="mb-3 grid size-11 place-items-center rounded-full bg-[#30d158] text-[#04180b]">
                <Check className="size-5" />
              </span>
              <div className="text-sm text-muted-foreground">
                Saved into the project's exports folder and downloaded.
              </div>
            </div>
            <DialogFooter>
              <Button className="w-full" onClick={close}>
                Done
              </Button>
            </DialogFooter>
          </>
        )}

        {status === "error" && (
          <>
            <div>
              <div className="mb-2 text-sm font-medium text-destructive">
                Export didn't finish
              </div>
              <pre className="max-h-36 overflow-auto rounded-lg border border-border bg-background p-2.5 font-mono text-[10.5px] leading-relaxed break-words whitespace-pre-wrap text-muted-foreground select-text">
                {error}
              </pre>
            </div>
            <DialogFooter>
              <Button variant="ghost" onClick={close}>
                Close
              </Button>
              <Button onClick={() => useExport.getState().dismiss()}>Try again</Button>
            </DialogFooter>
          </>
        )}
      </DialogContent>
    </Dialog>
  );
}
