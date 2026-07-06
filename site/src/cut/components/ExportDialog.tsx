"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { Check, FolderCheck } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  EXPORT_PRESETS,
  originalSettings,
  presetSettings,
  startExport,
  type ExportHandle,
} from "@/cut/lib/exportClient";
import { useEditor } from "@/cut/lib/store";
import { cn } from "@/lib/utils";

type Phase =
  | { kind: "idle" }
  | { kind: "running"; stage: string; ratio: number }
  | { kind: "done"; outName: string }
  | { kind: "error"; message: string };

export function ExportDialog() {
  const setExportOpen = useEditor((s) => s.setExportOpen);
  const aspect = useEditor((s) => s.aspect);
  const clips = useEditor((s) => s.clips);
  const assets = useEditor((s) => s.assets);
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
  const [phase, setPhase] = useState<Phase>({ kind: "idle" });
  const handleRef = useRef<ExportHandle | null>(null);

  useEffect(() => () => handleRef.current?.cancel(), []);

  const close = () => {
    handleRef.current?.cancel();
    setExportOpen(false);
  };

  const run = () => {
    const s = useEditor.getState();
    if (!s.projectId) return;
    const settings = (presets.find((p) => p.id === presetId) ?? presets[0]).settings;
    const handle = startExport(
      s.projectId,
      {
        assets: s.assets,
        clips: s.clips,
        audioClips: s.audioClips,
        overlays: s.overlays,
        subtitles: s.subtitles,
      },
      settings,
      (stage, ratio) => setPhase({ kind: "running", stage, ratio })
    );
    handleRef.current = handle;
    handle.done
      .then(({ outName }) => setPhase({ kind: "done", outName }))
      .catch((err: unknown) =>
        setPhase({ kind: "error", message: err instanceof Error ? err.message : String(err) })
      );
  };

  return (
    <Dialog open onOpenChange={(o) => !o && close()}>
      <DialogContent className="sm:max-w-sm">
        <DialogHeader>
          <DialogTitle>Export</DialogTitle>
        </DialogHeader>

        {phase.kind === "idle" && (
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

        {phase.kind === "running" && (
          <div className="pt-1">
            <div className="h-1.5 overflow-hidden rounded-full bg-secondary">
              <div
                className="h-full rounded-full bg-primary transition-[width] duration-300"
                style={{ width: `${Math.round(phase.ratio * 100)}%` }}
              />
            </div>
            <div className="mt-2.5 flex justify-between text-xs text-muted-foreground">
              <span>{phase.stage}</span>
              <span className="font-mono tabular-nums">{Math.round(phase.ratio * 100)}%</span>
            </div>
            <DialogFooter className="mt-4">
              <Button variant="ghost" onClick={close}>
                Cancel
              </Button>
            </DialogFooter>
          </div>
        )}

        {phase.kind === "done" && (
          <div className="flex flex-col items-center pt-2 text-center">
            <span className="mb-3 grid size-11 place-items-center rounded-full bg-[#30d158] text-[#04180b]">
              <Check className="size-5" />
            </span>
            <div className="text-[15px] font-semibold">Exported</div>
            <div className="mt-1 flex items-center gap-1.5 text-sm text-muted-foreground">
              <FolderCheck className="size-3.5" />
              Saved into the project’s exports folder and downloaded.
            </div>
            <DialogFooter className="mt-4 w-full">
              <Button className="w-full" onClick={() => setExportOpen(false)}>
                Done
              </Button>
            </DialogFooter>
          </div>
        )}

        {phase.kind === "error" && (
          <div>
            <div className="mb-2 text-sm font-medium text-destructive">
              Export didn’t finish
            </div>
            <pre className="max-h-36 overflow-auto rounded-lg border border-border bg-background p-2.5 font-mono text-[10.5px] leading-relaxed break-words whitespace-pre-wrap text-muted-foreground select-text">
              {phase.message}
            </pre>
            <DialogFooter className="mt-4">
              <Button variant="ghost" onClick={close}>
                Close
              </Button>
              <Button onClick={() => setPhase({ kind: "idle" })}>Try again</Button>
            </DialogFooter>
          </div>
        )}
      </DialogContent>
    </Dialog>
  );
}
