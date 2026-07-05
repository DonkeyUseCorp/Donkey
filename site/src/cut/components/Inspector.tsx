"use client";

import { useEffect, useRef, useState } from "react";
import { Bold } from "lucide-react";
import { Button } from "@/components/ui/button";
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
import { useEditor } from "@/cut/lib/store";
import { PLATE_RADIUS } from "@/cut/lib/textRender";
import { formatTime } from "@/cut/lib/time";
import { FONTS, type AudioClip, type TextOverlay, type VideoClip } from "@/cut/lib/types";
import { cn } from "@/lib/utils";

const SWATCHES = ["#FFFFFF", "#111114", "#FFD60A", "#FF375F", "#0A84FF", "#30D158"];

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

  return (
    <aside className="flex min-h-0 flex-col overflow-y-auto border-l border-border bg-card">
      {clip ? (
        <ClipPanel clip={clip} />
      ) : audio ? (
        <AudioPanel clip={audio} />
      ) : overlay ? (
        <TextPanel overlay={overlay} />
      ) : null}
    </aside>
  );
}

function PanelTitle({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex h-10 shrink-0 items-center px-3.5 text-[11px] font-semibold tracking-widest text-muted-foreground uppercase">
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

function ClipPanel({ clip }: { clip: VideoClip }) {
  const asset = useEditor((s) => s.assets.find((a) => a.id === clip.assetId));
  const updateClip = useEditor((s) => s.updateClip);
  return (
    <>
      <PanelTitle>Video clip</PanelTitle>
      <div className="flex flex-col gap-1 px-3.5 pb-4">
        <div className="mb-1.5 truncate border-b border-border pb-2.5 text-xs font-medium" title={asset?.name}>
          {asset?.name}
        </div>
        <Row label="Length"><Value>{formatTime(clip.out - clip.in)}</Value></Row>
        <Row label="Trim">
          <Value>{formatTime(clip.in)} – {formatTime(clip.out)}</Value>
        </Row>
        <Row label="Mute audio">
          <Switch
            checked={clip.muted}
            onCheckedChange={(v) => updateClip(clip.id, { muted: v })}
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
        <p className="mt-2.5 text-[11.5px] leading-relaxed text-muted-foreground">
          {clip.fit === "fill"
            ? "Fill crops the video to cover the frame — drag it in the preview to choose what stays visible."
            : "Drag the clip edges on the timeline to trim it. Fit letterboxes the whole picture; Fill crops it to cover the frame."}
        </p>
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
  // A fade can take at most half the clip so in+out never overlap.
  const maxFade = Math.max(0.1, Math.round(((clip.out - clip.in) / 2) * 10) / 10);
  return (
    <>
      <PanelTitle>Soundtrack</PanelTitle>
      <div className="flex flex-col gap-1 px-3.5 pb-4">
        <div className="mb-1.5 truncate border-b border-border pb-2.5 text-xs font-medium" title={asset?.name}>
          {asset?.name}
        </div>
        <Row label="Length"><Value>{formatTime(clip.out - clip.in)}</Value></Row>
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
      </div>
    </>
  );
}

function TextPanel({ overlay: o }: { overlay: TextOverlay }) {
  const update = useEditor((s) => s.updateOverlay);
  const sizeCk = useSliderCheckpoint();
  const radiusCk = useSliderCheckpoint();
  const [recents, setRecents] = useState<string[]>([]);
  useEffect(() => setRecents(readRecentColors()), []);

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
    <>
      <PanelTitle>Title</PanelTitle>
      <div className="flex flex-col gap-1 px-3.5 pb-4">
        <Textarea
          className="mb-2 min-h-16 select-text"
          rows={3}
          value={o.text}
          onChange={(e) =>
            useEditor.getState().updateOverlayTransient(o.id, { text: e.target.value })
          }
          onFocus={() => useEditor.getState().pushHistory()}
        />
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
          <div className="flex max-w-44 flex-wrap items-center justify-end gap-1.5">
            {[...SWATCHES, ...recents].map((c) => (
              <button
                key={c}
                title={c}
                aria-label={`Color ${c}`}
                className={cn(
                  "size-5 rounded-full border border-black/15 transition-transform hover:scale-110",
                  o.color.toUpperCase() === c.toUpperCase() &&
                    "ring-2 ring-primary ring-offset-2 ring-offset-card"
                )}
                style={{ background: c }}
                onClick={() => update(o.id, { color: c })}
              />
            ))}
            <label
              title="Custom color"
              className="color-picker-well relative size-5 cursor-pointer rounded-full border border-black/15 bg-[conic-gradient(from_0deg,#f43f5e,#f59e0b,#84cc16,#06b6d4,#6366f1,#d946ef,#f43f5e)] transition-transform hover:scale-110"
            >
              <span className="absolute inset-1 rounded-full bg-card" />
              <span className="absolute inset-[5px] rounded-full" style={{ background: o.color }} />
              <input
                type="color"
                aria-label="Pick a custom color"
                className="absolute inset-0 size-full cursor-pointer opacity-0"
                value={/^#[0-9a-fA-F]{6}$/.test(o.color) ? o.color : "#ffffff"}
                onFocus={() => useEditor.getState().pushHistory()}
                onChange={(e) =>
                  useEditor.getState().updateOverlayTransient(o.id, { color: e.target.value })
                }
                onBlur={() => {
                  const c = useEditor
                    .getState()
                    .overlays.find((x) => x.id === o.id)?.color;
                  if (c) recordRecent(c);
                }}
              />
            </label>
          </div>
        </Row>
        <Row label="Shadow">
          <Switch checked={o.shadow} onCheckedChange={(v) => update(o.id, { shadow: v })} />
        </Row>
        <Row label="Backdrop">
          <Switch checked={o.plate} onCheckedChange={(v) => update(o.id, { plate: v })} />
        </Row>
        {o.plate && (
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
        )}
        <p className="mt-2.5 text-[11.5px] leading-relaxed text-muted-foreground">
          Drag the title in the preview to place it; use the corner handle to resize.
        </p>
      </div>
    </>
  );
}
