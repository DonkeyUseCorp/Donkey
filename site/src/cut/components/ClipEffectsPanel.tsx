"use client";

import { Fragment, useRef, useState } from "react";
import {
  ArrowDown,
  ArrowDownToLine,
  ArrowLeft,
  ArrowLeftToLine,
  ArrowRight,
  ArrowRightToLine,
  ArrowUp,
  ArrowUpToLine,
  Ban,
  Blend,
  ChevronLeft,
  Circle,
  Droplets,
  Expand,
  FoldHorizontal,
  Haze,
  Moon,
  Sparkles,
  Sun,
  Target,
  UnfoldHorizontal,
  ZoomIn,
  type LucideIcon,
} from "lucide-react";
import { Slider } from "@/components/ui/slider";
import { parsePercentInput, parseSecondsInput, ScrubValue } from "@/cut/components/ScrubValue";
import { getClipSpans, useEditor } from "@/cut/lib/store";
import { lookCssFilter } from "@/cut/lib/looks";
import {
  ANIM_DEFAULT_SECONDS,
  ANIM_STYLE_IDS,
  ANIM_STYLE_LABELS,
  LOOK_IDS,
  LOOK_LABELS,
  TRANSITION_MAX,
  TRANSITION_STYLE_GROUPS,
  TRANSITION_STYLE_LABELS,
  type AnimStyle,
  type LookStyle,
  type TransitionStyle,
  type VideoClip,
} from "@/cut/lib/types";
import { cn } from "@/lib/utils";

const TRANSITION_TILE_ICONS: Record<TransitionStyle, LucideIcon> = {
  crossfade: Blend,
  crosszoom: Expand,
  dipblack: Moon,
  dipwhite: Sun,
  blur: Droplets,
  pushleft: ArrowLeft,
  pushright: ArrowRight,
  pushup: ArrowUp,
  pushdown: ArrowDown,
  wipeleft: ArrowLeftToLine,
  wiperight: ArrowRightToLine,
  wipeup: ArrowUpToLine,
  wipedown: ArrowDownToLine,
  circleopen: Circle,
  circleclose: Target,
  splitopen: UnfoldHorizontal,
  splitclose: FoldHorizontal,
};

const ANIM_TILE_ICONS: Record<AnimStyle, LucideIcon> = {
  fade: Haze,
  zoom: ZoomIn,
  pop: Sparkles,
  slideleft: ArrowLeft,
  slideright: ArrowRight,
  slideup: ArrowUp,
  slidedown: ArrowDown,
};

/** The entry row's compact readout: which effect categories are set (the row
 * is 8.5rem wide — exact style names don't fit, the tabs inside do). */
export function effectsSummary(clip: VideoClip, hasNext: boolean): string {
  const parts: string[] = [];
  if (hasNext && (clip.transition ?? 0) > 0) parts.push("Transition");
  if (clip.animIn) parts.push("In");
  if (clip.animOut) parts.push("Out");
  if (clip.look) parts.push("Look");
  return parts.join(" · ") || "None";
}

/** One undo checkpoint per slider drag (mirrors the Inspector's helper —
 * importing it would cycle back through Inspector). */
function useSliderCheckpoint() {
  const active = useRef(false);
  return {
    begin() {
      if (active.current) return;
      active.current = true;
      useEditor.getState().pushHistory();
    },
    end() {
      active.current = false;
    },
  };
}

function Tile({
  selected,
  onClick,
  label,
  className,
  children,
}: {
  selected: boolean;
  onClick: () => void;
  label: string;
  className?: string;
  children: React.ReactNode;
}) {
  return (
    <button
      type="button"
      aria-pressed={selected}
      className={cn(
        "flex flex-col items-center gap-1.5 rounded-lg border border-border p-2.5 text-[11px] font-medium text-muted-foreground transition-colors hover:bg-muted/60 hover:text-foreground",
        selected && "bg-primary/10 text-foreground ring-2 ring-[#0a84ff] ring-offset-1 ring-offset-card",
        className
      )}
      onClick={onClick}
    >
      {children}
      <span className="leading-none">{label}</span>
    </button>
  );
}

function GridLabel({ children }: { children: React.ReactNode }) {
  return (
    <div className="col-span-2 mt-1.5 text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground/70 first:mt-0">
      {children}
    </div>
  );
}

type Tab = "transition" | "in" | "out" | "looks";

/**
 * The effects sub-page a clip panel pushes into: segmented tabs over card
 * grids — the transition into the next clip, the clip's own entrance/exit
 * animations, and its filter look — with the active effect's duration or
 * intensity slider beneath the grid.
 */
export function ClipEffectsPanel({
  clip,
  hasNext,
  onBack,
}: {
  clip: VideoClip;
  hasNext: boolean;
  onBack: () => void;
}) {
  const [tab, setTab] = useState<Tab>(hasNext ? "transition" : "in");
  const [xfadeDraft, setXfadeDraft] = useState<number | null>(null);
  const ck = useSliderCheckpoint();
  // Upper tracks composite via alpha, so only the animations expressible as
  // alpha/zoom ramps are offered there (the rest would silently degrade).
  const animStyles = clip.track > 0 ? (["fade", "zoom"] as AnimStyle[]) : ANIM_STYLE_IDS;
  const xfade = xfadeDraft ?? clip.transition ?? 0;

  // Picking or retuning an effect immediately plays the affected stretch of
  // the real timeline in the preview — seek just ahead of it, play, and
  // auto-pause just after — so every option shows itself on the actual
  // footage. Windows are computed from fresh state (setting a transition can
  // slide the following clips).
  const PREVIEW_LEAD = 0.4;
  const PREVIEW_TAIL = 0.35;
  const previewTransition = () => {
    const s = useEditor.getState();
    const spans = getClipSpans(s.clips, s.assets, clip.track);
    const i = spans.findIndex((sp) => sp.clip.id === clip.id);
    const sp = spans[i];
    const next = spans[i + 1];
    if (!sp || !next || sp.transitionOut <= 0) return;
    s.previewRange(next.start - PREVIEW_LEAD, next.start + sp.transitionOut + PREVIEW_TAIL);
  };
  const previewAnim = (which: "in" | "out") => {
    const s = useEditor.getState();
    const sp = getClipSpans(s.clips, s.assets, clip.track).find((x) => x.clip.id === clip.id);
    const fresh = s.clips.find((c) => c.id === clip.id);
    const a = which === "in" ? fresh?.animIn : fresh?.animOut;
    if (!sp || !a) return;
    if (which === "in") s.previewRange(sp.start - 0.25, sp.start + a.seconds + PREVIEW_TAIL);
    else s.previewRange(sp.start + sp.len - a.seconds - PREVIEW_LEAD, sp.start + sp.len + 0.25);
  };
  const previewLook = () => {
    // A look is static — landing the playhead on the clip's own footage
    // shows it instantly; no play-through needed.
    const s = useEditor.getState();
    const sp = getClipSpans(s.clips, s.assets, clip.track).find((x) => x.clip.id === clip.id);
    if (!sp) return;
    if (s.currentTime < sp.start || s.currentTime >= sp.start + sp.len) {
      s.seek(sp.start + sp.len / 2);
    }
  };

  const pickTransition = (style: TransitionStyle | null) => {
    // Picking a style with the length still at zero turns the transition on
    // at a sensible default.
    if (style === null) {
      useEditor.getState().setClipTransition(clip.id, 0);
      return;
    }
    useEditor.getState().setClipTransition(clip.id, xfade >= 0.05 ? xfade : 0.5, style);
    previewTransition();
  };
  const pickAnim = (which: "in" | "out", style: AnimStyle | null) => {
    const current = which === "in" ? clip.animIn : clip.animOut;
    useEditor
      .getState()
      .setClipAnim(
        clip.id,
        which,
        style ? { style, seconds: current?.seconds ?? ANIM_DEFAULT_SECONDS } : null
      );
    if (style) previewAnim(which);
  };
  const setAnimSeconds = (which: "in" | "out", seconds: number) => {
    const current = which === "in" ? clip.animIn : clip.animOut;
    if (!current) return;
    ck.begin();
    useEditor.getState().updateClipTransient(clip.id, {
      [which === "in" ? "animIn" : "animOut"]: {
        style: current.style,
        seconds: Math.max(0.1, Math.min(TRANSITION_MAX, seconds)),
      },
    });
  };
  const setLookAmount = (v: number) => {
    if (!clip.look) return;
    ck.begin();
    useEditor.getState().updateClipTransient(clip.id, {
      lookAmount: v >= 1 ? undefined : Math.max(0.05, v),
    });
  };

  const tabs: { id: Tab; label: string; disabled?: boolean; title?: string }[] = [
    {
      id: "transition",
      label: "Transition",
      disabled: !hasNext,
      title: hasNext ? undefined : "Needs a following clip on this track",
    },
    { id: "in", label: "In" },
    { id: "out", label: "Out" },
    { id: "looks", label: "Looks" },
  ];
  // Never sit on a disabled tab (e.g. picking a transition disables Out while
  // Out is open): fall to the first enabled one.
  const activeTab = tabs.find((t) => t.id === tab && !t.disabled)
    ? tab
    : (tabs.find((t) => !t.disabled)?.id ?? "looks");
  const anim = activeTab === "in" ? clip.animIn : activeTab === "out" ? clip.animOut : undefined;

  return (
    <>
      <div className="flex h-10 shrink-0 items-center gap-1 px-2.5 text-sm font-semibold tracking-tight">
        <button
          type="button"
          aria-label="Back"
          className="clip-fx-back grid size-6 place-items-center rounded text-muted-foreground transition-colors hover:text-foreground"
          onClick={onBack}
        >
          <ChevronLeft className="size-4" />
        </button>
        Effects
      </div>
      <div className="flex flex-col gap-2 px-3.5 pb-4">
        <div className="flex shrink-0 rounded-lg bg-muted p-0.5 text-[11.5px] font-medium">
          {tabs.map((t) => (
            <button
              key={t.id}
              type="button"
              disabled={t.disabled}
              title={t.title}
              className={cn(
                "clip-fx-tab flex-1 rounded-md px-1.5 py-1 transition-colors",
                activeTab === t.id
                  ? "bg-neutral-900 text-white"
                  : "text-muted-foreground hover:text-foreground",
                t.disabled && "cursor-not-allowed opacity-40 hover:text-muted-foreground"
              )}
              onClick={() => !t.disabled && setTab(t.id)}
            >
              {t.label}
            </button>
          ))}
        </div>

        {activeTab === "transition" && (
          <>
            <div className="grid grid-cols-2 gap-1.5">
              <Tile
                selected={(clip.transition ?? 0) <= 0}
                onClick={() => pickTransition(null)}
                label="None"
                className="clip-fx-none"
              >
                <Ban className="size-4" />
              </Tile>
              {TRANSITION_STYLE_GROUPS.map((g) => (
                <Fragment key={g.label}>
                  <GridLabel>{g.label}</GridLabel>
                  {g.ids.map((id) => {
                    const Icon = TRANSITION_TILE_ICONS[id];
                    return (
                      <Tile
                        key={id}
                        selected={
                          (clip.transition ?? 0) > 0 && (clip.transitionStyle ?? "crossfade") === id
                        }
                        onClick={() => pickTransition(id)}
                        label={TRANSITION_STYLE_LABELS[id]}
                        className={`clip-fx-t-${id}`}
                      >
                        <Icon className="size-4" />
                      </Tile>
                    );
                  })}
                </Fragment>
              ))}
            </div>
            {(clip.transition ?? 0) > 0 && (
              <div className="flex items-center gap-2 pt-1">
                <span className="w-14 shrink-0 text-[11.5px] text-muted-foreground">Length</span>
                <Slider
                  className="clip-xfade data-horizontal:w-24"
                  min={0.1}
                  max={TRANSITION_MAX}
                  step={0.1}
                  value={xfade}
                  onValueChange={(v) => setXfadeDraft(Number(v))}
                  onValueCommitted={() => {
                    if (xfadeDraft != null) {
                      useEditor.getState().setClipTransition(clip.id, xfadeDraft);
                      previewTransition();
                    }
                    setXfadeDraft(null);
                  }}
                />
                <ScrubValue
                  label="Transition length"
                  className="w-9 text-muted-foreground"
                  value={xfade}
                  min={0}
                  max={TRANSITION_MAX}
                  step={0.1}
                  format={(v) => `${v.toFixed(1)}s`}
                  parse={parseSecondsInput}
                  onScrub={setXfadeDraft}
                  onCommit={(v) => {
                    useEditor.getState().setClipTransition(clip.id, v);
                    previewTransition();
                    setXfadeDraft(null);
                  }}
                />
              </div>
            )}
          </>
        )}

        {(activeTab === "in" || activeTab === "out") && (
          <>
            <div className="grid grid-cols-2 gap-1.5">
              <Tile
                selected={!anim}
                onClick={() => pickAnim(activeTab, null)}
                label="None"
                className="clip-fx-none"
              >
                <Ban className="size-4" />
              </Tile>
              {animStyles.map((id) => {
                const Icon = ANIM_TILE_ICONS[id];
                return (
                  <Tile
                    key={id}
                    selected={anim?.style === id}
                    onClick={() => pickAnim(activeTab, id)}
                    label={ANIM_STYLE_LABELS[id]}
                    className={`clip-fx-a-${id}`}
                  >
                    <Icon className="size-4" />
                  </Tile>
                );
              })}
            </div>
            {anim && (
              <div className="flex items-center gap-2 pt-1">
                <span className="w-14 shrink-0 text-[11.5px] text-muted-foreground">Length</span>
                <Slider
                  className="clip-fx-anim-secs data-horizontal:w-24"
                  min={0.1}
                  max={TRANSITION_MAX}
                  step={0.1}
                  value={anim.seconds}
                  onValueChange={(v) => setAnimSeconds(activeTab, Number(v))}
                  onValueCommitted={() => {
                    ck.end();
                    previewAnim(activeTab);
                  }}
                />
                <ScrubValue
                  label="Animation length"
                  className="w-9 text-muted-foreground"
                  value={anim.seconds}
                  min={0.1}
                  max={TRANSITION_MAX}
                  step={0.1}
                  format={(v) => `${v.toFixed(1)}s`}
                  parse={parseSecondsInput}
                  onScrub={(v) => setAnimSeconds(activeTab, v)}
                  onCommit={(v) => {
                    setAnimSeconds(activeTab, v);
                    ck.end();
                    previewAnim(activeTab);
                  }}
                />
              </div>
            )}
          </>
        )}

        {activeTab === "looks" && (
          <>
            <div className="grid grid-cols-2 gap-1.5">
              <Tile
                selected={!clip.look}
                onClick={() => useEditor.getState().setClipLook(clip.id, null)}
                label="None"
                className="clip-fx-none"
              >
                <LookSwatch />
              </Tile>
              {LOOK_IDS.map((id) => (
                <Tile
                  key={id}
                  selected={clip.look === id}
                  onClick={() => {
                    useEditor.getState().setClipLook(clip.id, id, clip.lookAmount);
                    previewLook();
                  }}
                  label={LOOK_LABELS[id]}
                  className={`clip-fx-l-${id}`}
                >
                  <LookSwatch look={id} />
                </Tile>
              ))}
            </div>
            {clip.look && (
              <div className="flex items-center gap-2 pt-1">
                <span className="w-14 shrink-0 text-[11.5px] text-muted-foreground">Intensity</span>
                <Slider
                  className="clip-fx-look-amount data-horizontal:w-24"
                  min={0.05}
                  max={1}
                  step={0.05}
                  value={clip.lookAmount ?? 1}
                  onValueChange={(v) => setLookAmount(Number(v))}
                  onValueCommitted={() => ck.end()}
                />
                <ScrubValue
                  label="Look intensity"
                  className="w-9 text-muted-foreground"
                  value={clip.lookAmount ?? 1}
                  min={0.05}
                  max={1}
                  step={0.05}
                  format={(v) => `${Math.round(v * 100)}%`}
                  parse={parsePercentInput}
                  onScrub={setLookAmount}
                  onCommit={(v) => {
                    setLookAmount(v);
                    ck.end();
                  }}
                />
              </div>
            )}
          </>
        )}
      </div>
    </>
  );
}

/** A look tile's thumbnail: one shared colorful gradient run through the
 * look's own CSS filter, so the tiles are the single source of truth with the
 * preview grading. No look = the unfiltered gradient. */
function LookSwatch({ look }: { look?: LookStyle }) {
  return (
    <span
      aria-hidden
      className="h-8 w-full rounded-md"
      style={{
        background: "linear-gradient(135deg,#f59e0b 0%,#ec4899 50%,#3b82f6 100%)",
        filter: look ? lookCssFilter(look, 1) || undefined : undefined,
      }}
    />
  );
}
