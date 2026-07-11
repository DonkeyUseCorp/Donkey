"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Bold, Smile } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Slider } from "@/components/ui/slider";
import { Switch } from "@/components/ui/switch";
import { Textarea } from "@/components/ui/textarea";
import { getClipSpans, useEditor, type EditorState } from "@/cut/lib/store";
import { GenerateSubtitlesAudio } from "@/cut/components/VoicePicker";
import { PLATE_COLOR, PLATE_OPACITY, PLATE_RADIUS } from "@/cut/lib/textRender";
import { writeTextStyle } from "@/cut/lib/textStyle";
import { formatTime } from "@/cut/lib/time";
import {
  FONTS,
  LAYOUTS,
  rectOf,
  regionLabel,
  SPEED_MAX,
  SPEED_MIN,
  TRANSITION_MAX,
  TRANSITION_STYLE_IDS,
  TRANSITION_STYLE_LABELS,
  type AudioClip,
  type FrameRect,
  type LayoutId,
  type OverlayClip,
  type TextOverlay,
  type TransitionStyle,
  type VideoClip,
} from "@/cut/lib/types";
import { cn } from "@/lib/utils";

const SWATCHES = ["#FFFFFF", "#111114", "#FFD60A", "#FF375F", "#0A84FF", "#30D158"];

// A compact set of social-friendly emoji for the text editor. These are plain
// unicode, so they render with the viewer's system emoji font.
const EMOJIS = [
  "🔥", "😂", "😮", "😍", "💯", "👀", "🎉", "✨",
  "🙌", "💪", "🤯", "👇", "👉", "❤️", "😅", "🥶",
  "🚀", "💡", "⚡", "🤔", "😱", "👍", "🙏", "💸",
];

/** Last three custom colors picked with the eyedropper, newest first. */
const RECENT_COLORS_KEY = "cut-recent-colors";

/**
 * One undo checkpoint per slider drag: capture the pre-drag state on the first
 * change, then feed live changes through the transient updater so the whole
 * drag collapses to a single ⌘Z. Reset when the interaction commits.
 */
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

function readRecentColors(): string[] {
  try {
    const v = JSON.parse(localStorage.getItem(RECENT_COLORS_KEY) ?? "[]") as unknown;
    return Array.isArray(v) ? v.filter((x): x is string => typeof x === "string").slice(0, 3) : [];
  } catch {
    return [];
  }
}

/** Preset swatches, recent custom colors, and an eyedropper. `onBegin` marks
 * an undo checkpoint, `onLive` streams the drag, `onCommit` sets a final pick. */
function ColorSwatches({
  value,
  onBegin,
  onLive,
  onCommit,
}: {
  value: string;
  onBegin: () => void;
  onLive: (c: string) => void;
  onCommit: (c: string) => void;
}) {
  const [recents, setRecents] = useState<string[]>(() =>
    typeof window === "undefined" ? [] : readRecentColors()
  );

  const recordRecent = (c: string) => {
    if (SWATCHES.some((s) => s.toUpperCase() === c.toUpperCase())) return;
    const next = [c, ...recents.filter((r) => r.toUpperCase() !== c.toUpperCase())].slice(0, 3);
    setRecents(next);
    try {
      localStorage.setItem(RECENT_COLORS_KEY, JSON.stringify(next));
    } catch {
      // Storage full/blocked — recents just won't persist.
    }
  };

  return (
    <div className="flex max-w-44 flex-wrap items-center justify-end gap-1.5">
      {[...SWATCHES, ...recents].map((c) => (
        <button
          key={c}
          title={c}
          aria-label={`Color ${c}`}
          className={cn(
            "size-5 rounded-full border border-black/15 transition-transform hover:scale-110",
            value.toUpperCase() === c.toUpperCase() &&
              "ring-2 ring-primary ring-offset-2 ring-offset-card"
          )}
          style={{ background: c }}
          onClick={() => onCommit(c)}
        />
      ))}
      <label
        title="Custom color"
        className="color-picker-well relative size-5 cursor-pointer rounded-full border border-black/15 bg-[conic-gradient(from_0deg,#f43f5e,#f59e0b,#84cc16,#06b6d4,#6366f1,#d946ef,#f43f5e)] transition-transform hover:scale-110"
      >
        <span className="absolute inset-1 rounded-full bg-card" />
        <span className="absolute inset-[5px] rounded-full" style={{ background: value }} />
        <input
          type="color"
          aria-label="Pick a custom color"
          className="absolute inset-0 size-full cursor-pointer opacity-0"
          value={/^#[0-9a-fA-F]{6}$/.test(value) ? value : "#ffffff"}
          onFocus={onBegin}
          onChange={(e) => onLive(e.target.value)}
          onBlur={() => recordRecent(value)}
        />
      </label>
    </div>
  );
}

export function Inspector() {
  const selection = useEditor((s) => s.selection);
  const clip = useEditor((s) =>
    selection?.kind === "clip" ? s.clips.find((c) => c.id === selection.id) : undefined
  );
  const audio = useEditor((s) =>
    selection?.kind === "audio" ? s.audioClips.find((c) => c.id === selection.id) : undefined
  );
  const overlay = useEditor((s) =>
    selection?.kind === "text" ? s.overlays.find((o) => o.id === selection.id) : undefined
  );
  const overlayClip = useEditor((s) =>
    selection?.kind === "overlayClip" ? s.overlayClips.find((c) => c.id === selection.id) : undefined
  );

  return (
    <aside className="flex min-h-0 flex-col overflow-y-auto border-l border-border bg-card">
      {clip ? (
        <ClipPanel key={clip.id} clip={clip} />
      ) : audio ? (
        <AudioPanel key={audio.id} clip={audio} />
      ) : overlayClip ? (
        <OverlayClipPanel key={overlayClip.id} clip={overlayClip} />
      ) : overlay ? (
        <TextPanel key={overlay.id} overlay={overlay} />
      ) : null}
    </aside>
  );
}

function PanelTitle({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex h-10 shrink-0 items-center px-3.5 text-sm font-semibold tracking-tight">
      {children}
    </div>
  );
}

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex min-h-9 items-center justify-between gap-2.5">
      <span className="shrink-0 text-[13px] text-muted-foreground">{label}</span>
      <div className="flex min-w-0 items-center gap-2">{children}</div>
    </div>
  );
}

const Value = ({ children, className }: { children: React.ReactNode; className?: string }) => (
  <span className={cn("font-mono text-[11.5px] tabular-nums", className)}>{children}</span>
);

/** One-click frame layouts (Full / Top / Bottom / Left / Right / PiP) shared by
 * the video-clip and overlay-clip panels. Picking one regions the clip so two
 * videos can share the frame; "Full" clears the region. */
function LayoutButtons({
  rect,
  onPick,
}: {
  rect: FrameRect;
  onPick: (frame: FrameRect | undefined, fit: "fit" | "fill") => void;
}) {
  const currentId =
    (Object.keys(LAYOUTS) as LayoutId[]).find((id) => LAYOUTS[id].label === regionLabel(rect)) ??
    "full";
  return (
    <div className="flex items-center justify-between gap-2 py-1">
      <span className="text-[11.5px] font-medium text-muted-foreground">Layout</span>
      <Select
        value={currentId}
        items={Object.fromEntries((Object.keys(LAYOUTS) as LayoutId[]).map((id) => [id, LAYOUTS[id].label]))}
        onValueChange={(id) => {
          const L = LAYOUTS[id as LayoutId];
          onPick(id === "full" ? undefined : { ...L.rect }, L.fit);
        }}
      >
        <SelectTrigger className="h-8 w-36 text-[12px]">
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          {(Object.keys(LAYOUTS) as LayoutId[]).map((id) => (
            <SelectItem key={id} value={id} className="text-[12px]">
              {LAYOUTS[id].label}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
    </div>
  );
}

function ClipPanel({ clip }: { clip: VideoClip }) {
  const asset = useEditor((s) => s.assets.find((a) => a.id === clip.assetId));
  const updateClip = useEditor((s) => s.updateClip);
  // A transition hands this clip into the next one, so only offer it when
  // there is a next clip on the track.
  const hasNext = useEditor((s) => {
    const i = s.clips.findIndex((c) => c.id === clip.id);
    return i >= 0 && i < s.clips.length - 1;
  });
  // The whole-video fades are project-level but live on the clips that show
  // them: fade in on the first clip's panel, fade out on the last clip's.
  const isFirst = useEditor((s) => s.clips[0]?.id === clip.id);
  const isLast = useEditor((s) => s.clips[s.clips.length - 1]?.id === clip.id);
  const fadeIn = useEditor((s) => s.fadeIn);
  const fadeOut = useEditor((s) => s.fadeOut);
  const [speedDraft, setSpeedDraft] = useState<number | null>(null);
  const [xfadeDraft, setXfadeDraft] = useState<number | null>(null);
  const [volumeDraft, setVolumeDraft] = useState<number | null>(null);
  const volume = volumeDraft ?? clip.volume ?? 1;
  // Subtitle cues overlapping this clip's timeline span, for the per-clip
  // readout. A selector rather than a snapshot so the generate button reads
  // fresh ids after it auto-transcribes the cut.
  const selectClipCueIds = useCallback(
    (s: EditorState) => {
      const sp = getClipSpans(s.clips, s.assets).find((x) => x.clip.id === clip.id);
      if (!sp) return [];
      return s.subtitles.cues
        .filter((c) => c.text.trim() && c.end > sp.start && c.start < sp.start + sp.len)
        .map((c) => c.id);
    },
    [clip.id]
  );
  const ensureClipCues = useCallback(
    () => useEditor.getState().generateClipSubtitles(clip.id),
    [clip.id]
  );
  // Generated voiceover clips overlapping this clip's span — the "Generated
  // audio" slider drives them all, so clip sound and voiceover balance from one
  // panel. Same joined-string trick as the cue ids for reference stability.
  const [genVolDraft, setGenVolDraft] = useState<number | null>(null);
  const genCk = useSliderCheckpoint();
  const genAudioKey = useEditor((s) => {
    const sp = getClipSpans(s.clips, s.assets).find((x) => x.clip.id === clip.id);
    if (!sp) return "";
    const voiceAssets = new Set(
      s.assets.filter((a) => a.origin === "voiceover").map((a) => a.id)
    );
    return s.audioClips
      .filter((a) => {
        const len = (a.out - a.in) / (a.speed && a.speed > 0 ? a.speed : 1);
        return (
          voiceAssets.has(a.assetId) && a.start < sp.start + sp.len && a.start + len > sp.start
        );
      })
      .map((a) => a.id)
      .join("\n");
  });
  const genAudioIds = useMemo(() => (genAudioKey ? genAudioKey.split("\n") : []), [genAudioKey]);
  const genVolStore = useEditor((s) => {
    const first = s.audioClips.find((a) => a.id === genAudioIds[0]);
    return first ? first.volume : 1;
  });
  const genVol = genVolDraft ?? genVolStore;
  const speed = speedDraft ?? clip.speed ?? 1;
  const xfade = xfadeDraft ?? clip.transition ?? 0;
  const speedLen = (clip.out - clip.in) / (speed > 0 ? speed : 1);
  return (
    <>
      <PanelTitle>Video clip</PanelTitle>
      <div className="flex flex-col gap-1 px-3.5 pb-4">
        <div className="mb-1.5 truncate border-b border-border pb-2.5 text-xs font-medium" title={asset?.name}>
          {asset?.name}
        </div>
        <Row label="Length"><Value>{formatTime(speedLen)}</Value></Row>
        <Row label="Trim">
          <Value>{formatTime(clip.in)} – {formatTime(clip.out)}</Value>
        </Row>
        <Row label="Speed">
          <Slider
            className="clip-speed data-horizontal:w-24"
            min={SPEED_MIN}
            max={SPEED_MAX}
            step={0.05}
            value={speed}
            onValueChange={(v) => setSpeedDraft(Number(v))}
            onValueCommitted={() => {
              if (speedDraft != null) useEditor.getState().setClipSpeed(clip.id, speedDraft);
              setSpeedDraft(null);
            }}
          />
          <Value className="w-9 text-right text-muted-foreground">{speed.toFixed(2)}×</Value>
        </Row>
        {isFirst && (
          <Row label="Fade in">
            <Slider
              className="project-fade-in data-horizontal:w-24"
              min={0}
              max={TRANSITION_MAX}
              step={0.1}
              value={fadeIn}
              onValueChange={(v) => useEditor.getState().setProjectFade({ fadeIn: Number(v) })}
            />
            <Value className="w-9 text-right text-muted-foreground">
              {fadeIn < 0.05 ? "Off" : `${fadeIn.toFixed(1)}s`}
            </Value>
          </Row>
        )}
        {isLast && (
          <Row label="Fade out">
            <Slider
              className="project-fade-out data-horizontal:w-24"
              min={0}
              max={TRANSITION_MAX}
              step={0.1}
              value={fadeOut}
              onValueChange={(v) => useEditor.getState().setProjectFade({ fadeOut: Number(v) })}
            />
            <Value className="w-9 text-right text-muted-foreground">
              {fadeOut < 0.05 ? "Off" : `${fadeOut.toFixed(1)}s`}
            </Value>
          </Row>
        )}
        {hasNext && (
          <>
            <Row label="Transition">
              <Select
                value={clip.transitionStyle ?? "crossfade"}
                items={TRANSITION_STYLE_LABELS}
                onValueChange={(v) =>
                  // Picking a style with the length still at zero turns the
                  // transition on at a sensible default.
                  useEditor
                    .getState()
                    .setClipTransition(clip.id, xfade >= 0.05 ? xfade : 0.5, v as TransitionStyle)
                }
              >
                <SelectTrigger className="clip-transition-style h-7 w-[8.5rem] text-[12px]">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {TRANSITION_STYLE_IDS.map((id) => (
                    <SelectItem key={id} value={id} className="text-[12px]">
                      {TRANSITION_STYLE_LABELS[id]}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </Row>
            <Row label="Length">
              <Slider
                className="clip-xfade data-horizontal:w-24"
                min={0}
                max={TRANSITION_MAX}
                step={0.1}
                value={xfade}
                onValueChange={(v) => setXfadeDraft(Number(v))}
                onValueCommitted={() => {
                  if (xfadeDraft != null) useEditor.getState().setClipTransition(clip.id, xfadeDraft);
                  setXfadeDraft(null);
                }}
              />
              <Value className="w-9 text-right text-muted-foreground">
                {xfade < 0.05 ? "Off" : `${xfade.toFixed(1)}s`}
              </Value>
            </Row>
          </>
        )}

        {/* Audio */}
        <div className="my-1.5 h-px bg-border" />
        <Row label="Clip volume">
          <Slider
            className="clip-volume data-horizontal:w-24"
            min={0}
            max={1.5}
            step={0.05}
            value={volume}
            onValueChange={(v) => setVolumeDraft(Number(v))}
            onValueCommitted={() => {
              if (volumeDraft != null) {
                updateClip(clip.id, { volume: volumeDraft === 1 ? undefined : volumeDraft });
              }
              setVolumeDraft(null);
            }}
          />
          <Value className="w-9 text-right text-muted-foreground">
            {Math.round(volume * 100)}%
          </Value>
        </Row>
        <Row label="Mute audio">
          <Switch
            checked={clip.muted}
            onCheckedChange={(v) => updateClip(clip.id, { muted: v })}
          />
        </Row>

        {/* Picture */}
        <div className="my-1.5 h-px bg-border" />
        <Row label="Hide from output">
          <Switch
            checked={!!clip.hidden}
            onCheckedChange={(v) => updateClip(clip.id, { hidden: v })}
          />
        </Row>
        <Row label="Framing">
          <div className="clip-framing flex rounded-lg border border-input p-0.5">
            {(["fit", "fill"] as const).map((mode) => (
              <button
                key={mode}
                className={cn(
                  "rounded-md px-2.5 py-1 text-[11.5px] font-medium transition-colors",
                  (clip.fit ?? "fit") === mode
                    ? "bg-neutral-900 text-white"
                    : "text-muted-foreground hover:text-foreground"
                )}
                aria-pressed={(clip.fit ?? "fit") === mode}
                onClick={() => updateClip(clip.id, { fit: mode, panX: 0, panY: 0 })}
              >
                {mode === "fit" ? "Fit" : "Fill"}
              </button>
            ))}
          </div>
        </Row>
        {clip.fit === "fill" && ((clip.panX ?? 0) !== 0 || (clip.panY ?? 0) !== 0) && (
          <Row label="Position">
            <button
              className="clip-recenter rounded-md border border-input px-2 py-0.5 text-[11.5px] text-muted-foreground transition-colors hover:text-foreground"
              onClick={() => updateClip(clip.id, { panX: 0, panY: 0 })}
            >
              Center
            </button>
          </Row>
        )}
        <LayoutButtons
          rect={rectOf(clip)}
          onPick={(frame, fit) => updateClip(clip.id, { frame, fit })}
        />
        <div className="mt-2 flex flex-col gap-1 border-t border-border pt-3">
          <GenerateSubtitlesAudio
            selectCueIds={selectClipCueIds}
            ensureCues={ensureClipCues}
            label="Generate audio for clip"
          />
          {genAudioIds.length > 0 && (
            <Row label="Volume">
              <Slider
                className="clip-gen-volume data-horizontal:w-24"
                min={0}
                max={1.5}
                step={0.05}
                value={genVol}
                onValueChange={(v) => {
                  genCk.begin();
                  setGenVolDraft(Number(v));
                  const s = useEditor.getState();
                  genAudioIds.forEach((id) => s.updateAudioTransient(id, { volume: Number(v) }));
                }}
                onValueCommitted={() => {
                  genCk.end();
                  setGenVolDraft(null);
                }}
              />
              <Value className="w-9 text-right text-muted-foreground">
                {Math.round(genVol * 100)}%
              </Value>
            </Row>
          )}
        </div>
      </div>
    </>
  );
}

function AudioPanel({ clip }: { clip: AudioClip }) {
  const asset = useEditor((s) => s.assets.find((a) => a.id === clip.assetId));
  const updateAudioTransient = useEditor((s) => s.updateAudioTransient);
  const ck = useSliderCheckpoint();
  const setAudio = (patch: Partial<AudioClip>) => {
    ck.begin();
    updateAudioTransient(clip.id, patch);
  };
  // Detached audio can carry a playback rate; its timeline length is (out-in)/speed.
  const speed = clip.speed && clip.speed > 0 ? clip.speed : 1;
  const len = (clip.out - clip.in) / speed;
  // A fade can take at most half the clip so in+out never overlap.
  const maxFade = Math.max(0.1, Math.round((len / 2) * 10) / 10);
  return (
    <>
      <PanelTitle>Soundtrack</PanelTitle>
      <div className="flex flex-col gap-1 px-3.5 pb-4">
        <div className="mb-1.5 truncate border-b border-border pb-2.5 text-xs font-medium" title={asset?.name}>
          {asset?.name}
        </div>
        <Row label="Length"><Value>{formatTime(len)}</Value></Row>
        <Row label="Starts at"><Value>{formatTime(clip.start)}</Value></Row>
        <Row label="Volume">
          <Slider
            className="data-horizontal:w-24"
            min={0}
            max={1.5}
            step={0.05}
            value={clip.volume}
            onValueChange={(v) => setAudio({ volume: Number(v) })}
            onValueCommitted={ck.end}
          />
          <Value className="w-9 text-right text-muted-foreground">
            {Math.round(clip.volume * 100)}%
          </Value>
        </Row>
        <Row label="Fade in">
          <Slider
            className="fade-in-slider data-horizontal:w-24"
            min={0}
            max={maxFade}
            step={0.1}
            value={clip.fadeIn ?? 0}
            onValueChange={(v) => setAudio({ fadeIn: Number(v) })}
            onValueCommitted={ck.end}
          />
          <Value className="w-9 text-right text-muted-foreground">
            {(clip.fadeIn ?? 0).toFixed(1)}s
          </Value>
        </Row>
        <Row label="Fade out">
          <Slider
            className="fade-out-slider data-horizontal:w-24"
            min={0}
            max={maxFade}
            step={0.1}
            value={clip.fadeOut ?? 0}
            onValueChange={(v) => setAudio({ fadeOut: Number(v) })}
            onValueCommitted={ck.end}
          />
          <Value className="w-9 text-right text-muted-foreground">
            {(clip.fadeOut ?? 0).toFixed(1)}s
          </Value>
        </Row>
        <Row label="Duck others">
          <Slider
            className="duck-slider data-horizontal:w-24"
            min={0}
            max={1}
            step={0.05}
            value={clip.duck ?? 1}
            onValueChange={(v) => {
              const n = Number(v);
              setAudio({ duck: n < 0.999 ? n : undefined });
            }}
            onValueCommitted={ck.end}
          />
          <Value className="w-9 text-right text-muted-foreground">
            {clip.duck === undefined ? "Off" : `${Math.round(clip.duck * 100)}%`}
          </Value>
        </Row>
        {clip.duck !== undefined && (
          <p className="text-[11px] leading-relaxed text-muted-foreground">
            While this clip plays, everything else drops to {Math.round(clip.duck * 100)}% volume.
          </p>
        )}
        <Row label="Hide from output">
          <Switch
            checked={!!clip.hidden}
            onCheckedChange={(v) => useEditor.getState().updateAudio(clip.id, { hidden: v })}
          />
        </Row>
      </div>
    </>
  );
}

function OverlayClipPanel({ clip }: { clip: OverlayClip }) {
  const asset = useEditor((s) => s.assets.find((a) => a.id === clip.assetId));
  const update = useEditor((s) => s.updateOverlayClip);
  const speed = clip.speed && clip.speed > 0 ? clip.speed : 1;
  const len = (clip.out - clip.in) / speed;
  return (
    <>
      <PanelTitle>Overlay clip</PanelTitle>
      <div className="flex flex-col gap-1 px-3.5 pb-4">
        <div className="mb-1.5 truncate border-b border-border pb-2.5 text-xs font-medium" title={asset?.name}>
          {asset?.name}
        </div>
        <Row label="Length"><Value>{formatTime(len)}</Value></Row>
        <Row label="Starts at"><Value>{formatTime(clip.start)}</Value></Row>
        <LayoutButtons
          rect={rectOf(clip)}
          onPick={(frame, fit) => update(clip.id, { frame, fit })}
        />
        <Row label="Framing">
          <div className="flex rounded-lg border border-input p-0.5">
            {(["fit", "fill"] as const).map((mode) => (
              <button
                key={mode}
                className={cn(
                  "rounded-md px-2.5 py-1 text-[11.5px] font-medium transition-colors",
                  (clip.fit ?? "fit") === mode
                    ? "bg-neutral-900 text-white"
                    : "text-muted-foreground hover:text-foreground"
                )}
                onClick={() => update(clip.id, { fit: mode })}
              >
                {mode === "fit" ? "Fit" : "Fill"}
              </button>
            ))}
          </div>
        </Row>
        <Row label="Mute audio">
          <Switch checked={clip.muted} onCheckedChange={(v) => update(clip.id, { muted: v })} />
        </Row>
        <Row label="Hide from output">
          <Switch checked={!!clip.hidden} onCheckedChange={(v) => update(clip.id, { hidden: v })} />
        </Row>
      </div>
    </>
  );
}

function TextPanel({ overlay: o }: { overlay: TextOverlay }) {
  const update = useEditor((s) => s.updateOverlay);
  const sizeCk = useSliderCheckpoint();
  const radiusCk = useSliderCheckpoint();
  const opacityCk = useSliderCheckpoint();
  const taRef = useRef<HTMLTextAreaElement>(null);

  // Remember this title's look across clips and projects, so the next new title
  // starts from the same style.
  useEffect(() => {
    writeTextStyle({
      size: o.size,
      font: o.font,
      weight: o.weight,
      color: o.color,
      shadow: o.shadow,
      plate: o.plate,
      plateColor: o.plateColor,
      plateOpacity: o.plateOpacity,
      plateRadius: o.plateRadius,
    });
  }, [o.size, o.font, o.weight, o.color, o.shadow, o.plate, o.plateColor, o.plateOpacity, o.plateRadius]);

  const insertEmoji = (emoji: string) => {
    const ta = taRef.current;
    const s = useEditor.getState();
    s.pushHistory();
    const start = ta?.selectionStart ?? o.text.length;
    const end = ta?.selectionEnd ?? start;
    const next = o.text.slice(0, start) + emoji + o.text.slice(end);
    s.updateOverlayTransient(o.id, { text: next });
    requestAnimationFrame(() => {
      const pos = start + emoji.length;
      ta?.focus();
      ta?.setSelectionRange(pos, pos);
    });
  };

  return (
    <>
      <PanelTitle>Text</PanelTitle>
      <div className="flex flex-col gap-1 px-3.5 pb-4">
        <div className="relative mb-2">
          <Textarea
            ref={taRef}
            className="min-h-16 select-text pr-9"
            rows={3}
            value={o.text}
            onChange={(e) =>
              useEditor.getState().updateOverlayTransient(o.id, { text: e.target.value })
            }
            onFocus={() => useEditor.getState().pushHistory()}
          />
          <DropdownMenu>
            <DropdownMenuTrigger
              render={
                <Button
                  variant="ghost"
                  size="icon-sm"
                  aria-label="Insert emoji"
                  title="Insert emoji"
                  className="absolute top-1.5 right-1.5 text-muted-foreground"
                />
              }
            >
              <Smile />
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end" className="grid grid-cols-8 gap-0.5 p-1.5">
              {EMOJIS.map((e) => (
                <button
                  key={e}
                  type="button"
                  className="grid size-7 place-items-center rounded text-lg hover:bg-accent"
                  onClick={() => insertEmoji(e)}
                >
                  {e}
                </button>
              ))}
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
        <Row label="Font">
          <Select
            value={o.font}
            items={Object.fromEntries(FONTS.map((f) => [f.id, f.label]))}
            onValueChange={(v) => update(o.id, { font: v as TextOverlay["font"] })}
          >
            <SelectTrigger size="sm" className="w-28">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {FONTS.map((f) => (
                <SelectItem key={f.id} value={f.id}>
                  {f.label}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
          <Button
            variant="outline"
            size="icon-sm"
            aria-label="Bold"
            aria-pressed={o.weight === 700}
            className={cn(o.weight === 700 && "border-primary bg-primary/15 text-primary")}
            onClick={() => update(o.id, { weight: o.weight === 700 ? 400 : 700 })}
          >
            <Bold />
          </Button>
        </Row>
        <Row label="Size">
          <Slider
            className="data-horizontal:w-24"
            min={24}
            max={240}
            value={o.size}
            onValueChange={(v) => {
              sizeCk.begin();
              useEditor.getState().updateOverlayTransient(o.id, { size: Number(v) });
            }}
            onValueCommitted={sizeCk.end}
          />
          <Value className="w-9 text-right text-muted-foreground">{o.size}</Value>
        </Row>
        <Row label="Color">
          <ColorSwatches
            value={o.color}
            onBegin={() => useEditor.getState().pushHistory()}
            onLive={(c) => useEditor.getState().updateOverlayTransient(o.id, { color: c })}
            onCommit={(c) => update(o.id, { color: c })}
          />
        </Row>
        <Row label="Shadow">
          <Switch checked={o.shadow} onCheckedChange={(v) => update(o.id, { shadow: v })} />
        </Row>
        <Row label="Backdrop">
          <Switch checked={o.plate} onCheckedChange={(v) => update(o.id, { plate: v })} />
        </Row>
        {o.plate && (
          <>
            <Row label="Backdrop color">
              <ColorSwatches
                value={o.plateColor ?? PLATE_COLOR}
                onBegin={() => useEditor.getState().pushHistory()}
                onLive={(c) => useEditor.getState().updateOverlayTransient(o.id, { plateColor: c })}
                onCommit={(c) => update(o.id, { plateColor: c })}
              />
            </Row>
            <Row label="Opacity">
              <Slider
                className="data-horizontal:w-24"
                min={0}
                max={1}
                step={0.01}
                value={o.plateOpacity ?? PLATE_OPACITY}
                onValueChange={(v) => {
                  opacityCk.begin();
                  useEditor.getState().updateOverlayTransient(o.id, { plateOpacity: Number(v) });
                }}
                onValueCommitted={opacityCk.end}
              />
              <Value className="w-9 text-right text-muted-foreground">
                {Math.round((o.plateOpacity ?? PLATE_OPACITY) * 100)}
              </Value>
            </Row>
            <Row label="Radius">
              <Slider
                className="data-horizontal:w-24"
                min={0}
                max={1}
                step={0.01}
                value={o.plateRadius ?? PLATE_RADIUS}
                onValueChange={(v) => {
                  radiusCk.begin();
                  useEditor.getState().updateOverlayTransient(o.id, { plateRadius: Number(v) });
                }}
                onValueCommitted={radiusCk.end}
              />
              <Value className="w-9 text-right text-muted-foreground">
                {Math.round((o.plateRadius ?? PLATE_RADIUS) * 100)}
              </Value>
            </Row>
          </>
        )}
        <p className="mt-2.5 text-[11.5px] leading-relaxed text-muted-foreground">
          Drag the title in the preview to place it; use the corner handle to resize.
        </p>
      </div>
    </>
  );
}
