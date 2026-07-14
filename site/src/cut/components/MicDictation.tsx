"use client";

import { Check, Mic, X } from "lucide-react";
import { cn } from "@/lib/utils";
import { useMicTranscription, type MicController } from "@/cut/lib/micTranscribe";
import { LiveWaveform } from "./RecordDialog";

// Shared voice-dictation UI, used by every prompt input (the AI chat composer
// and the image / video / audio generation prompts). The capture + on-device
// transcription live in lib/micTranscribe.ts; this is the presentation:
//  - DictationBody: the read-only live transcript over a level meter, with
//    cancel (✕) and use (✓). The chat renders it inline; embedded inputs render
//    it inside an overlay.
//  - DictationControl: a mic trigger plus that overlay, for dropping into any
//    input whose container is `relative`.

/** Append a fresh transcript after whatever the user had already typed. */
export function appendTranscript(existing: string, transcript: string): string {
  const base = existing.trim();
  return base ? `${base} ${transcript}` : transcript;
}

/** The live transcript + waveform + controls. `text` is the input's current
 * value, shown muted alongside the evolving partial. */
export function DictationBody({
  text,
  mic,
  className,
}: {
  text: string;
  mic: MicController;
  className?: string;
}) {
  const shown = [text.trim(), mic.partial].filter(Boolean).join(" ");
  const finishing = mic.state === "finishing";
  return (
    <div className={cn("flex min-h-[72px] flex-col", className)}>
      <div className="min-h-0 flex-1 overflow-y-auto px-3 pt-2.5">
        <p className="text-[12.5px] leading-relaxed text-muted-foreground/80 italic">
          {shown || "Listening…"}
        </p>
      </div>
      <div className="flex items-center gap-2 px-2 pt-1 pb-2">
        {mic.stream ? (
          <LiveWaveform
            stream={mic.stream}
            sampleMs={130}
            className="h-7 min-w-0 flex-1 text-muted-foreground/70"
          />
        ) : (
          <div className="flex-1" />
        )}
        <button
          type="button"
          title="Cancel"
          disabled={finishing}
          onClick={mic.cancel}
          className="grid size-7 place-items-center rounded-lg bg-muted text-muted-foreground transition-colors hover:bg-muted/70 disabled:opacity-50"
        >
          <X className="size-3.5" />
        </button>
        <button
          type="button"
          title="Use transcription"
          disabled={finishing}
          onClick={() => void mic.confirm()}
          className="grid size-7 place-items-center rounded-lg bg-[#0a84ff] text-white transition-colors hover:bg-[#0a84ff]/90 disabled:opacity-50"
        >
          <Check className="size-3.5" />
        </button>
      </div>
    </div>
  );
}

/** A mic trigger that, while recording, overlays its input with the live
 * transcript. Drop it inside a `relative` container; on confirm the transcript
 * is appended to `text` via `onResult`. */
export function DictationControl({
  text,
  onResult,
  buttonClassName,
  disabled,
}: {
  text: string;
  onResult: (transcript: string) => void;
  buttonClassName?: string;
  disabled?: boolean;
}) {
  const mic = useMicTranscription((t) => onResult(appendTranscript(text, t)));
  return (
    <>
      {mic.state !== "idle" && (
        <div className="absolute inset-0 z-20 overflow-hidden rounded-[inherit] bg-background/95 backdrop-blur-sm">
          <DictationBody text={text} mic={mic} className="h-full" />
        </div>
      )}
      {mic.state === "idle" && (
        <button
          type="button"
          title="Dictate"
          disabled={disabled}
          onClick={() => void mic.start()}
          className={cn(
            "grid size-7 place-items-center rounded-md text-muted-foreground/70 transition-colors hover:bg-muted hover:text-foreground disabled:opacity-40",
            buttonClassName
          )}
        >
          <Mic className="size-3.5" />
        </button>
      )}
      {mic.error && mic.state === "idle" && (
        <div className="absolute right-1 bottom-full z-30 mb-1 max-w-[240px] rounded-md bg-popover px-2 py-1 text-[10.5px] leading-snug text-amber-700 shadow-md">
          {mic.error}
        </div>
      )}
    </>
  );
}
