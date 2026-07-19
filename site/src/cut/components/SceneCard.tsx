"use client";

import { useEffect, useRef, useState } from "react";
import {
  Check,
  ChevronRight,
  CircleDashed,
  Clapperboard,
  Maximize2,
  TriangleAlert,
  X,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { refFromAsset, type AssetRef } from "../lib/assetRef";
import { lightboxItemFromRef, useLightbox } from "../lib/lightbox";
import { formatDuration, useGenScene, type SceneRun } from "../lib/genScene";
import { NO_CREDITS_MESSAGE } from "../lib/generate";
import { GEN_FPS } from "../lib/genvideo/editorBridge";
import { useEditor } from "../lib/store";
import { formatTime } from "../lib/time";
import type { MediaAsset } from "../lib/types";
import type { Shot, ShotStatus } from "../lib/genvideo/types";
import { cn } from "@/lib/utils";
import { HostedErrorText } from "./hostedError";
import { scrimIconButton } from "./iconButton";
import { RefThumb } from "./AssetRefs";

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

export function SceneCard({ threadId }: { threadId: string }) {
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
  // The card belongs to the thread that asked — a new or different chat starts
  // clean. A run with no owner (pre-chatId persisted plans) shows anywhere.
  if (run.chatId && run.chatId !== threadId) return null;

  const inFlight = run.status === "planning" || run.status === "generating";
  const canDismiss =
    run.status === "awaiting_approval" || run.status === "done" || run.status === "failed";
  const pct = run.total ? Math.round((run.placed / run.total) * 100) : 0;
  const showProgress = run.status === "generating" || run.status === "done";
  const totalFrames = run.shots.length ? Math.max(...run.shots.map((sh) => sh.endFrame)) : 0;
  // Shots that couldn't be rendered as video and are holding a still instead.
  const stillCount = run.shots.filter((sh) => sh.status === "failed").length;
  // Any shot stopped by an empty balance: the summary names the cause (the
  // composer's credits tab carries the reload link).
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
                      <span className="mt-0.5 block pl-6 text-[10px] text-amber-700">
                        Couldn&apos;t animate — showing a still
                        {sh.error ? (
                          <>
                            : <HostedErrorText error={sh.error} link={false} />
                          </>
                        ) : null}
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
            <HostedErrorText error={run.error} link={false} />
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
          {run.status === "failed" && (
            // Failed is a deliberate stop (nothing auto-resumes it); the run
            // continues only through this click, skipping work already done.
            <Button
              size="sm"
              className="h-7 flex-1 text-[11.5px]"
              onClick={() => useGenScene.getState().retryRun()}
            >
              Retry
            </Button>
          )}
          {run.status === "done" && stillCount === 0 && (
            <span className="flex flex-1 items-center gap-1 text-emerald-600">
              <Check className="size-3.5" /> Video ready
            </span>
          )}
          {run.status === "done" && stillCount > 0 && (
            <>
              <span className="flex flex-1 items-start gap-1 text-[10.5px] text-amber-700">
                <TriangleAlert className="mt-px size-3 shrink-0" />
                <span>
                  {stillCount} of {run.shots.length} shot{run.shots.length === 1 ? "" : "s"} held a
                  still —{" "}
                  {creditsOut ? (
                    <HostedErrorText error={NO_CREDITS_MESSAGE} link={false} />
                  ) : (
                    "video generation failed"
                  )}
                </span>
              </span>
              <Button
                size="sm"
                className="h-7 text-[11.5px]"
                onClick={() => useGenScene.getState().retryFailedShots()}
              >
                Retry {stillCount} shot{stillCount === 1 ? "" : "s"}
              </Button>
            </>
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

/** The run's chronological record, streamed into the chat as its own item
 * right under the scene card — every narrated step and every asset it made,
 * thumbnails included. Nothing the run does is internal: this is the same
 * story the agent would tell in chat. */
export function SceneActivity({ threadId }: { threadId: string }) {
  const run = useGenScene((s) => s.run);
  const projectId = useEditor((s) => s.projectId);
  // Feed thumbnails resolve against the open project's media (the run's
  // assets are project assets, chat-owned).
  const assets = useEditor((s) => s.assets);

  // Follow new entries only when the chat is already reading the tail —
  // never yank the user back down while they scroll through old images.
  const bottomRef = useRef<HTMLDivElement>(null);
  const feedLen = run?.feed.length ?? 0;
  useEffect(() => {
    const scroller = bottomRef.current?.closest(".ai-messages");
    if (!scroller) return;
    const gap = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight;
    if (gap < 160) scroller.scrollTop = scroller.scrollHeight;
  }, [feedLen]);

  if (!run || run.projectId !== projectId) return null;
  if (run.chatId && run.chatId !== threadId) return null;
  if (run.feed.length === 0) return null;
  const inFlight = run.status === "planning" || run.status === "generating";

  return (
    <div className="ai-scene-activity mt-2 mb-3 flex flex-col gap-1.5">
      <div className="text-[10.5px] font-medium text-muted-foreground">Activity</div>
      {run.feed.map((f, i) => {
        const asset = f.mediaId ? assets.find((a) => a.id === f.mediaId) : undefined;
        const ref = asset ? refFromAsset(asset) : undefined;
        const latest = i === run.feed.length - 1;
        return (
          <FeedEntry
            key={`${f.at}-${i}`}
            text={f.text}
            item={ref}
            asset={asset}
            pulse={latest && inFlight}
          />
        );
      })}
      <div ref={bottomRef} />
    </div>
  );
}

/** One feed line. Clicking the thumbnail expands the media in place — the same
 * inline tile chat asset cards use — and a second click collapses it back;
 * the tile's corner button opens the lightbox. */
function FeedEntry({
  text,
  item,
  asset,
  pulse,
}: {
  text: string;
  item?: AssetRef;
  asset?: MediaAsset;
  pulse: boolean;
}) {
  const [expanded, setExpanded] = useState(false);
  const inPlace = item?.kind === "image" || item?.kind === "video";
  const caption = (
    <span
      className={`min-w-0 flex-1 text-[11px] text-muted-foreground ${pulse ? "animate-pulse" : ""}`}
    >
      {text}
    </span>
  );

  if (item && inPlace && expanded) {
    const ratio =
      asset?.width && asset?.height
        ? asset.width / asset.height
        : item.kind === "image"
          ? 1
          : 16 / 10;
    const width = Math.round(Math.min(248, Math.max(132, 210 * ratio)));
    return (
      <div className="flex flex-col items-start gap-1">
        <div
          className="group relative cursor-zoom-out overflow-hidden rounded-xl border border-border bg-muted"
          style={{ width, aspectRatio: ratio }}
          title={`${item.name} — click to minimize`}
          onClick={() => setExpanded(false)}
        >
          {item.kind === "video" ? (
            <video
              src={`${item.url}#t=0.1`}
              preload="metadata"
              muted
              playsInline
              className="size-full object-cover"
            />
          ) : (
            // eslint-disable-next-line @next/next/no-img-element -- engine/static file, not Next-optimizable
            <img src={item.url} alt={item.name} className="size-full object-cover" />
          )}
          {item.kind === "video" && item.duration !== undefined && (
            <span className="absolute right-1.5 bottom-1.5 rounded-[5px] bg-black/65 px-1 py-px font-mono text-[9px] text-white tabular-nums">
              {formatTime(item.duration)}
            </span>
          )}
          <button
            title="Expand"
            className={cn(
              scrimIconButton,
              "absolute top-1 right-1 opacity-0 transition-opacity group-hover:opacity-100"
            )}
            onClick={(e) => {
              e.stopPropagation();
              useLightbox.getState().open(lightboxItemFromRef(item));
            }}
          >
            <Maximize2 className="size-3" />
          </button>
        </div>
        {caption}
      </div>
    );
  }

  return (
    <div className="flex items-center gap-2">
      {item && (
        <button
          type="button"
          title={`${item.name} — click to view`}
          className="shrink-0"
          onClick={() =>
            inPlace
              ? setExpanded(true)
              : useLightbox.getState().open(lightboxItemFromRef(item))
          }
        >
          <RefThumb item={item} className="size-8 rounded-[4px]" />
        </button>
      )}
      {caption}
    </div>
  );
}
