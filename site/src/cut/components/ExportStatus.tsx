"use client";

import { Check, FolderOpen, Loader2, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useElapsed } from "@/cut/hooks/useElapsed";
import { revealExport } from "@/cut/lib/exportClient";
import { useExport } from "@/cut/lib/exportStore";
import { useEditor } from "@/cut/lib/store";

/** A small floating chip that tracks a background export after the dialog is
 * closed, so the render keeps going and the result is still one click away. */
export function ExportStatus() {
  const status = useExport((s) => s.status);
  const ratio = useExport((s) => s.ratio);
  const outName = useExport((s) => s.outName);
  const projectId = useExport((s) => s.projectId);
  const startedAt = useExport((s) => s.startedAt);
  const exportOpen = useEditor((s) => s.exportOpen);
  const elapsed = useElapsed(status === "running" ? startedAt : null);

  // The dialog owns the UI while it's open.
  if (exportOpen || status === "idle") return null;

  return (
    <div className="fixed right-4 bottom-4 z-50 flex items-center gap-2.5 rounded-xl border border-border bg-card px-3 py-2 shadow-lg">
      {status === "running" && (
        <>
          <Loader2 className="size-4 animate-spin text-primary" />
          <span className="text-xs font-medium">
            Exporting…{" "}
            <span className="tabular-nums text-muted-foreground">
              {Math.round(ratio * 100)}%{elapsed ? ` · ${elapsed}` : ""}
            </span>
          </span>
          <Button
            variant="ghost"
            size="icon-xs"
            aria-label="Cancel export"
            onClick={() => useExport.getState().cancel()}
          >
            <X />
          </Button>
        </>
      )}
      {status === "done" && (
        <>
          <span className="grid size-5 place-items-center rounded-full bg-[#30d158] text-[#04180b]">
            <Check className="size-3" />
          </span>
          <span className="text-xs font-medium">Export ready</span>
          {projectId && outName && (
            <Button
              variant="ghost"
              size="icon-xs"
              aria-label="Show in Finder"
              title="Show in Finder"
              onClick={() => void revealExport(projectId, outName).catch(() => {})}
            >
              <FolderOpen />
            </Button>
          )}
          <Button
            variant="ghost"
            size="icon-xs"
            aria-label="Dismiss"
            onClick={() => useExport.getState().dismiss()}
          >
            <X />
          </Button>
        </>
      )}
      {status === "error" && (
        <>
          <span className="text-xs font-medium text-destructive">Export failed</span>
          <Button
            variant="ghost"
            size="icon-xs"
            aria-label="Dismiss"
            onClick={() => useExport.getState().dismiss()}
          >
            <X />
          </Button>
        </>
      )}
    </div>
  );
}
