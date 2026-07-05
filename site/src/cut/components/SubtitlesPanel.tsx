"use client";

import { memo, useEffect, useRef, useState } from "react";
import { AlertCircle, Captions, ChevronDown, Loader2, RefreshCw } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Switch } from "@/components/ui/switch";
import { fmtCueTime } from "@/cut/lib/subtitles";
import { TIMELINE_H_MIN, useEditor } from "@/cut/lib/store";
import type { SubtitleCue } from "@/cut/lib/types";
import { cn } from "@/lib/utils";

const LOCALES = [
  ["en-US", "English (US)"],
  ["en-GB", "English (UK)"],
  ["es-ES", "Español"],
  ["fr-FR", "Français"],
  ["de-DE", "Deutsch"],
  ["it-IT", "Italiano"],
  ["pt-BR", "Português (BR)"],
  ["ja-JP", "日本語"],
  ["ko-KR", "한국어"],
  ["zh-CN", "中文"],
  ["vi-VN", "Tiếng Việt"],
] as const;

/** Give the cue track room when it appears. */
const TIMELINE_H_WITH_SUBS = Math.max(TIMELINE_H_MIN, 276);

export function SubtitlesPanel() {
  const subtitles = useEditor((s) => s.subtitles);
  const status = useEditor((s) => s.subtitleStatus);
  const error = useEditor((s) => s.subtitleError);
  const hasCues = subtitles.cues.length > 0;

  const generate = () => {
    const s = useEditor.getState();
    void s.generateSubtitles().then(() => {
      const cur = useEditor.getState();
      if (cur.subtitles.cues.length > 0 && cur.timelineH < TIMELINE_H_WITH_SUBS)
        cur.setTimelineH(TIMELINE_H_WITH_SUBS);
    });
  };

  return (
    <>
      <div className="flex h-12 shrink-0 items-center justify-between pr-2.5 pl-4">
        <span className="text-sm font-semibold tracking-tight">Subtitles</span>
        {hasCues && (
          <Button
            variant="ghost"
            size="sm"
            className="sub-regenerate"
            title="Transcribe the cut again (replaces these captions — undoable)"
            disabled={status === "running"}
            onClick={generate}
          >
            {status === "running" ? (
              <Loader2 className="animate-spin" />
            ) : (
              <RefreshCw />
            )}
            Regenerate
          </Button>
        )}
      </div>

      {!hasCues ? (
        <EmptyState status={status} error={error} onGenerate={generate} />
      ) : (
        <>
          <div className="flex shrink-0 flex-col gap-2 border-b border-border px-4 pb-3">
            <label className="flex items-center justify-between text-xs font-medium">
              Show on video
              <Switch
                className="sub-show-video"
                checked={subtitles.showOnVideo}
                onCheckedChange={(v) => useEditor.getState().setSubtitlesView({ showOnVideo: v })}
              />
            </label>
            <label className="flex items-center justify-between text-xs font-medium">
              Show on timeline
              <Switch
                className="sub-show-timeline"
                checked={subtitles.showOnTimeline}
                onCheckedChange={(v) => {
                  const s = useEditor.getState();
                  s.setSubtitlesView({ showOnTimeline: v });
                  if (v && s.timelineH < TIMELINE_H_WITH_SUBS) s.setTimelineH(TIMELINE_H_WITH_SUBS);
                }}
              />
            </label>
            {status === "running" && (
              <p className="flex items-center gap-1.5 text-[11px] text-muted-foreground">
                <Loader2 className="size-3 animate-spin" /> Re-transcribing on this Mac…
              </p>
            )}
            {status === "error" && error && (
              <p className="sub-error text-[11px] leading-relaxed text-red-600">{error}</p>
            )}
          </div>
          <Transcript cues={subtitles.cues} />
          <p className="shrink-0 border-t border-border px-4 py-2 text-[10.5px] leading-relaxed text-muted-foreground">
            Click a timestamp to jump there. Return splits a caption at the
            cursor (new timestamp) · ⌫ at the start merges it into the one
            before · delete all its text to remove it.
          </p>
        </>
      )}
    </>
  );
}

function EmptyState({
  status,
  error,
  onGenerate,
}: {
  status: string;
  error: string | null;
  onGenerate: () => void;
}) {
  const locale = useEditor((s) => s.subtitles.locale ?? "en-US");

  if (status === "running") {
    return (
      <div className="sub-generating flex flex-col items-center gap-3 px-6 pt-10 text-center">
        <Loader2 className="size-5 animate-spin text-muted-foreground" />
        <p className="text-[13px] font-medium">Transcribing on this Mac…</p>
        <p className="text-[11.5px] leading-relaxed text-muted-foreground">
          Runs in the background — keep editing. Captions appear here when
          it finishes.
        </p>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-3 px-3.5">
      {status === "empty" && (
        <p className="sub-empty pt-1 text-[11.5px] leading-relaxed text-muted-foreground">
          No speech was found in this cut, so no subtitles were added to the
          video.
        </p>
      )}
      {status === "error" && error && (
        <div className="sub-error flex items-start gap-2 rounded-lg bg-red-50 px-3 py-2.5 text-[11.5px] leading-relaxed text-red-700">
          <AlertCircle className="mt-0.5 size-3.5 shrink-0" />
          {error}
        </div>
      )}
      {status !== "empty" && (
        <div className="flex flex-col items-center gap-1 pt-4 pb-1 text-center">
          <Captions className="mb-1 size-6 text-muted-foreground" />
          <p className="text-[13px] font-semibold">Subtitles from your audio</p>
          <p className="text-[11.5px] leading-relaxed text-muted-foreground">
            Transcribed with Apple speech recognition, entirely on this Mac —
            your audio never leaves it.
          </p>
        </div>
      )}
      <div className="relative">
        <select
          className="sub-locale w-full appearance-none rounded-lg border border-input bg-transparent py-2 pr-9 pl-2.5 text-[12.5px] outline-none focus:border-ring"
          value={locale}
          onChange={(e) => useEditor.getState().setSubtitlesView({ locale: e.target.value })}
        >
          {LOCALES.map(([id, label]) => (
            <option key={id} value={id}>
              {label}
            </option>
          ))}
        </select>
        <ChevronDown className="pointer-events-none absolute top-1/2 right-3 size-4 -translate-y-1/2 text-muted-foreground" />
      </div>
      <Button className="sub-generate w-full" onClick={onGenerate}>
        <Captions data-icon="inline-start" />
        {status === "empty" || status === "error" ? "Try again" : "Generate subtitles"}
      </Button>
    </div>
  );
}

/** Opus-style flowing transcript: paragraphs of editable captions with
 * timestamp chips, plus pause chips where the speech leaves a gap. */
function Transcript({ cues }: { cues: SubtitleCue[] }) {
  // A pause over 2s starts a new paragraph; over 0.5s shows a pause chip.
  const paragraphs: { cue: SubtitleCue; gap: number }[][] = [];
  cues.forEach((cue, i) => {
    const gap = i === 0 ? 0 : cue.start - cues[i - 1].end;
    if (i === 0 || gap > 2) paragraphs.push([]);
    paragraphs[paragraphs.length - 1].push({ cue, gap });
  });

  return (
    <div className="sub-transcript min-h-0 flex-1 select-text overflow-y-auto px-4 py-3">
      {paragraphs.map((para) => (
        <p key={para[0].cue.id} className="mb-4 text-[12.5px] leading-[1.9]">
          {para.map(({ cue, gap }) => (
            <CueSpan key={cue.id} cue={cue} gap={gap} />
          ))}
        </p>
      ))}
    </div>
  );
}

function caretOffset(el: HTMLElement): number {
  const sel = window.getSelection();
  if (!sel || sel.rangeCount === 0) return 0;
  const range = sel.getRangeAt(0).cloneRange();
  range.selectNodeContents(el);
  range.setEnd(sel.getRangeAt(0).endContainer, sel.getRangeAt(0).endOffset);
  return range.toString().length;
}

const CueSpan = memo(function CueSpan({ cue, gap }: { cue: SubtitleCue; gap: number }) {
  const active = useEditor((s) => {
    const t = !s.playing && s.skimTime !== null ? s.skimTime : s.currentTime;
    return t >= cue.start && t < cue.end;
  });
  const ref = useRef<HTMLSpanElement>(null);
  const [focused, setFocused] = useState(false);

  // The span is uncontrolled while focused (so the caret survives typing);
  // outside edits (undo, regenerate) sync the DOM here.
  useEffect(() => {
    const el = ref.current;
    if (el && document.activeElement !== el && el.textContent !== cue.text)
      el.textContent = cue.text;
  }, [cue.text]);

  // Follow along during playback.
  useEffect(() => {
    if (active && useEditor.getState().playing)
      ref.current?.scrollIntoView({ block: "nearest", behavior: "smooth" });
  }, [active]);

  const commit = () => {
    setFocused(false);
    const el = ref.current;
    if (el) useEditor.getState().setCueText(cue.id, el.textContent ?? "");
  };

  return (
    <span className="sub-cue">
      {gap > 0.5 && (
        <span
          className="sub-gap mx-0.5 inline-block rounded-md bg-muted px-1.5 py-px align-baseline font-mono text-[10px] text-muted-foreground/80"
          title={`${gap.toFixed(1)}s pause`}
        >
          ·&thinsp;{gap.toFixed(1)}s&thinsp;·
        </span>
      )}
      <button
        className={cn(
          "sub-time mr-1 inline-block cursor-pointer rounded-md bg-muted px-1.5 py-px align-baseline font-mono text-[10px] tabular-nums text-muted-foreground transition-colors hover:bg-[#0a84ff]/15 hover:text-[#0a84ff]",
          active && "bg-[#0a84ff] text-white hover:bg-[#0a84ff] hover:text-white"
        )}
        title="Jump here"
        tabIndex={-1}
        onClick={() => useEditor.getState().seek(cue.start + 0.001)}
      >
        {fmtCueTime(cue.start)}
      </button>
      <span
        ref={ref}
        className={cn(
          "sub-text rounded-sm px-0.5 outline-none",
          active && "bg-[#0a84ff]/10",
          focused && "ring-1 ring-[#0a84ff]/40"
        )}
        contentEditable
        suppressContentEditableWarning
        spellCheck={false}
        data-cue={cue.id}
        onFocus={() => setFocused(true)}
        onBlur={commit}
        onKeyDown={(e) => {
          e.stopPropagation();
          const el = ref.current;
          if (!el) return;
          if (e.key === "Escape") {
            e.preventDefault();
            el.blur();
          } else if (e.key === "Enter") {
            e.preventDefault();
            const off = caretOffset(el);
            // Blur first: it commits any typing (dropping stale word
            // timings), then the split uses whatever timing survives.
            el.blur();
            useEditor.getState().splitCue(cue.id, off);
          } else if (e.key === "Backspace" && caretOffset(el) === 0 && window.getSelection()?.isCollapsed) {
            e.preventDefault();
            el.blur(); // commit typing (or delete the cue if emptied)
            useEditor.getState().mergeCueIntoPrev(cue.id);
          }
        }}
      />{" "}
    </span>
  );
});
