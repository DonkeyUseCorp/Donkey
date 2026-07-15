"use client";

import { useEffect, useState } from "react";
import { Check, ChevronRight, CircleDashed, Clapperboard, TriangleAlert, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { formatDuration, useGenScene, type SceneRun } from "../lib/genScene";
import { NO_CREDITS_MESSAGE } from "../lib/generate";
import { GEN_FPS } from "../lib/genvideo/editorBridge";
import { useEditor } from "../lib/store";
import type { Shot, ShotStatus } from "../lib/genvideo/types";
import { HostedErrorText } from "./hostedError";

// The brief-to-video progress card, pinned into the chat while a "generate a
// video" run is planning, waiting for approval, or rendering. The timeline fills
// on its own via the editor bridge; this is the control surface — approve the
// plan, watch shots land, redo one by clicking its chip.

const STATUS_LABEL: Record<SceneRun["status"], string> = {
  planning: "Planning",
  awaiting_approval: "Ready to render",
  generating: "Rendering",
  done: "Done",
  failed: "Failed",
};

/** Badge color by shot state: green when placed, amber when it fell back to a
 * still, blue while in flight, muted while pending. */
function shotTone(status: ShotStatus): string {
  if (status === "placed") return "border-emerald-500/30 bg-emerald-500/15 text-emerald-600";
  if (status === "failed") return "border-amber-500/30 bg-amber-500/15 text-amber-600";
  if (status === "pending") return "border-border bg-muted text-muted-foreground";
  return "border-[#0a84ff]/30 bg-[#0a84ff]/12 text-[#0a84ff]";
}

/** mm:ss for a frame count at the plan's fixed rate. */
function fmt(frames: number): string {
  return formatDuration((frames / GEN_FPS) * 1000);
}

/** The one line a plan row shows — what's on screen, else the spoken line. */
function describe(sh: Shot): string {
  return sh.action?.trim() || sh.dialogue?.trim() || sh.audioText?.trim() || "—";
}

export function SceneCard() {
  const run = useGenScene((s) => s.run);
  const projectId = useEditor((s) => s.projectId);
  const [open, setOpen] = useState(true);

  // Resuming a persisted run is the genScene store's own subscription — it
  // must happen even when this card (or the whole AI panel) never mounts.

  // The elapsed clock's "now", advanced once a second while the run works.
  // Held in state — Date.now() in render is impure — and set only from the
  // interval, so the first second shows 0:00 and a settled card renders from
  // its stamped times (a stale value clamps to zero, never shows).
  const [now, setNow] = useState<number | null>(null);
  const working = run?.status === "planning" || run?.status === "generating";
  useEffect(() => {
    if (!working) return;
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, [working]);

  if (!run || run.projectId !== projectId) return null;

  const inFlight = run.status === "planning" || run.status === "generating";
  const canDismiss =
    run.status === "awaiting_approval" || run.status === "done" || run.status === "failed";
  const pct = run.total ? Math.round((run.placed / run.total) * 100) : 0;
  const showProgress = run.status === "generating" || run.status === "done";
  const totalFrames = run.shots.length ? Math.max(...run.shots.map((sh) => sh.endFrame)) : 0;
  // Shots that couldn't be rendered as video and are holding a still instead.
  const stillCount = run.shots.filter((sh) => sh.status === "failed").length;
  // Any shot stopped by an empty balance: the summary carries the credits link.
  const creditsOut = run.shots.some(
    (sh) => sh.status === "failed" && sh.error === NO_CREDITS_MESSAGE
  );
  // Elapsed clock: planning counts from the run start, rendering from approval;
  // it stops at the end. Hidden while waiting for the user at the gate.
  const clockAnchor = run.status === "planning" ? run.startedAt : run.renderStartedAt ?? run.startedAt;
  const clockEnd = inFlight ? now ?? run.startedAt : run.endedAt ?? run.startedAt;
  const elapsed = run.status === "awaiting_approval" ? null : formatDuration(clockEnd - clockAnchor);

  return (
    <div className="ai-scene-card mt-2 rounded-xl border border-border bg-card/60 p-3 text-[11.5px]">
      <div className="flex items-center gap-1.5">
        <Clapperboard className="size-3.5 text-[#0a84ff]" />
        <span className="font-semibold">Generate video</span>
        <span className="ml-auto flex items-center gap-1 text-[10.5px] text-muted-foreground">
          {inFlight && <CircleDashed className="size-3 animate-spin" />}
          {STATUS_LABEL[run.status]}
          {elapsed && <span className="tabular-nums">· {elapsed}</span>}
        </span>
      </div>

      <p className="mt-1 line-clamp-2 text-muted-foreground">{run.title}</p>

      {run.status === "planning" && (
        <p className="mt-2 text-muted-foreground">Writing the script and planning shots…</p>
      )}

      {run.shots.length > 0 && (
        <div className="mt-2">
          <button
            type="button"
            onClick={() => setOpen((v) => !v)}
            className="flex w-full items-center gap-1.5 py-0.5 text-left text-muted-foreground hover:text-foreground"
          >
            <ChevronRight
              className={`size-3 shrink-0 transition-transform ${open ? "rotate-90" : ""}`}
            />
            <span className="font-medium text-foreground">Plan</span>
            <span>
              {run.shots.length} shot{run.shots.length === 1 ? "" : "s"} · {fmt(totalFrames)}
            </span>
            {showProgress && (
              <span className="ml-auto tabular-nums text-[10.5px]">
                {run.placed}/{run.total} placed
              </span>
            )}
          </button>

          {open && (
            <ol className="mt-1 flex flex-col gap-2">
              {run.shots.map((sh, i) => {
                // Redoable only once done — a click before then would render (and
                // bill) a shot the user never approved.
                const redoable = run.status === "done";
                return (
                  <li key={sh.id}>
                    <button
                      type="button"
                      disabled={!redoable}
                      onClick={() => useGenScene.getState().regenerateShot(i + 1)}
                      title={redoable ? "Click to redo this shot" : `Shot ${i + 1} — ${sh.status}`}
                      className={`flex w-full items-start gap-2 rounded-md py-0.5 text-left transition-colors ${
                        redoable ? "cursor-pointer hover:bg-muted/40" : "cursor-default"
                      }`}
                    >
                      <span
                        className={`mt-px grid size-4 shrink-0 place-items-center rounded-full text-[9.5px] font-medium ${shotTone(
                          sh.status
                        )}`}
                      >
                        {sh.status === "placed" ? <Check className="size-2.5" /> : i + 1}
                      </span>
                      <span className="min-w-0 flex-1">
                        <span className="mr-1.5 tabular-nums text-muted-foreground">
                          {fmt(sh.startFrame)}–{fmt(sh.endFrame)}
                        </span>
                        <span className="text-foreground/90">{describe(sh)}</span>
                      </span>
                    </button>
                    {sh.status === "failed" && (
                      // Outside the redo button: an empty-balance error carries
                      // the credits link, and a link can't live inside a button.
                      <span className="mt-0.5 block pl-6 text-[10px] text-amber-700">
                        Couldn&apos;t animate — showing a still
                        {sh.error ? (
                          <>
                            : <HostedErrorText error={sh.error} />
                          </>
                        ) : null}
                        {redoable ? ". Click the shot to retry." : ""}
                      </span>
                    )}
                  </li>
                );
              })}
            </ol>
          )}
        </div>
      )}

      {run.status === "generating" && (
        <div className="mt-2 h-1 overflow-hidden rounded-full bg-muted">
          <div
            className="h-full rounded-full bg-[#0a84ff] transition-all duration-500"
            style={{ width: `${pct}%` }}
          />
        </div>
      )}

      {run.error && (
        <p className="mt-2 flex items-start gap-1.5 text-amber-700">
          <TriangleAlert className="mt-px size-3 shrink-0" />
          <span>
            <HostedErrorText error={run.error} />
          </span>
        </p>
      )}

      {canDismiss && (
        <div className="mt-2.5 flex items-center gap-1.5">
          {run.status === "awaiting_approval" && (
            <Button
              size="sm"
              className="h-7 flex-1 text-[11.5px]"
              onClick={() => useGenScene.getState().approve()}
            >
              Approve &amp; render{run.shots.length ? ` (${run.shots.length})` : ""}
            </Button>
          )}
          {run.status === "done" && stillCount === 0 && (
            <span className="flex flex-1 items-center gap-1 text-emerald-600">
              <Check className="size-3.5" /> Video ready
            </span>
          )}
          {run.status === "done" && stillCount > 0 && (
            <span className="flex flex-1 items-start gap-1 text-[10.5px] text-amber-700">
              <TriangleAlert className="mt-px size-3 shrink-0" />
              <span>
                {stillCount} of {run.shots.length} shot{run.shots.length === 1 ? "" : "s"} held a
                still —{" "}
                {creditsOut ? (
                  <HostedErrorText error={NO_CREDITS_MESSAGE} />
                ) : (
                  "video generation failed"
                )}
                . Click a shot to retry.
              </span>
            </span>
          )}
          {canDismiss && (
            <Button
              size="sm"
              variant="ghost"
              className="h-7 text-muted-foreground"
              title="Dismiss"
              onClick={() => useGenScene.getState().dismiss()}
            >
              <X className="size-3.5" />
            </Button>
          )}
        </div>
      )}
    </div>
  );
}
