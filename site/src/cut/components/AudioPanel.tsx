"use client";

import { type DragEventHandler, useEffect, useRef, useState } from "react";
import {
  AudioLines,
  Check,
  ChevronDown,
  Info,
  Loader2,
  Pause,
  Play,
  Plus,
  Trash2,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { clearAssetDrag, setAssetDragData, setLibraryDragData } from "@/cut/lib/assetDrag";
import {
  addLibraryAssetToProject,
  fetchLibrary,
  libraryMediaUrl,
  type LibraryAsset,
} from "@/cut/lib/library";
import { creditsUrl, signInUrl, useSignedIn } from "@/cut/lib/generate";
import { enrichAsset } from "@/cut/lib/media";
import { useEditor } from "@/cut/lib/store";
import { formatTime } from "@/cut/lib/time";
import { NoCreditsError, synthesizeSpeech } from "@/cut/lib/tts";
import { DUCK_DEFAULT } from "@/cut/lib/voiceover";
import { useSpeakerVoice, useSpeechLanguage, VoicePicker } from "@/cut/components/VoicePicker";
import { cn } from "@/lib/utils";

/** Starting points for the direction prompt — picking one fills the input so
 * it can be tweaked before generating. */
const DIRECTION_PRESETS: { label: string; text: string }[] = [
  { label: "Warm", text: "Say warmly, like an old friend" },
  { label: "Energetic", text: "Say with high energy, like a hype announcer" },
  { label: "Documentary", text: "Narrate calmly and evenly, like a nature documentary" },
  { label: "Movie trailer", text: "Say dramatically, with gravity, like a movie trailer" },
  { label: "News anchor", text: "Read briskly and clearly, like a news anchor" },
  { label: "Whisper", text: "Whisper softly, close to the mic" },
  { label: "Bedtime story", text: "Read slowly and gently, like a bedtime story" },
];

/** The Audio tab: AI voiceover on top, then the project's and library's audio
 * as playable rows that drop onto the soundtrack at the playhead. Audio files
 * come in through the Media tab or a drop onto the timeline. */
export function AudioPanel({
  projectId,
  importing,
}: {
  projectId: string;
  importing: boolean;
}) {
  // One shared player for every row so starting a clip stops the last one.
  const player = useRef<HTMLAudioElement | null>(null);
  const [playingUrl, setPlayingUrl] = useState<string | null>(null);
  const togglePlay = (url: string) => {
    const el = (player.current ??= new Audio());
    if (playingUrl === url) {
      el.pause();
      setPlayingUrl(null);
      return;
    }
    el.src = url;
    el.onended = () => setPlayingUrl(null);
    el.onerror = () => setPlayingUrl(null);
    setPlayingUrl(url);
    void el.play().catch(() => setPlayingUrl(null));
  };
  useEffect(
    () => () => {
      player.current?.pause();
    },
    []
  );

  return (
    <>
      <div className="flex h-12 shrink-0 items-center pl-4">
        <span className="text-sm font-semibold tracking-tight">Audio</span>
      </div>

      <div className="flex min-h-0 flex-1 flex-col gap-5 overflow-y-auto px-3.5 pb-4">
        <VoiceGenerator projectId={projectId} />
        <ProjectAudio importing={importing} onTogglePlay={togglePlay} playingUrl={playingUrl} />
        <LibraryAudio projectId={projectId} onTogglePlay={togglePlay} playingUrl={playingUrl} />
      </div>
    </>
  );
}

function sectionLabel(text: string) {
  return (
    <span className="text-[11px] font-semibold tracking-wider text-muted-foreground uppercase">
      {text}
    </span>
  );
}

function VoiceGenerator({ projectId }: { projectId: string }) {
  const voice = useSpeakerVoice();
  const language = useSpeechLanguage();
  const [script, setScript] = useState("");
  const [direction, setDirection] = useState("");
  const [busy, setBusy] = useState(false);
  // `credits` marks a failure caused by an empty balance, which renders with a
  // link to buy more.
  const [error, setError] = useState<{ text: string; credits?: boolean } | null>(null);
  const fail = (e: unknown, fallback: string) =>
    setError(
      e instanceof Error
        ? { text: e.message, credits: e instanceof NoCreditsError }
        : { text: fallback }
    );
  const directionInput = useRef<HTMLTextAreaElement>(null);
  // Voiceovers run on the user's Donkey account, like image/video generation.
  const signedOut = useSignedIn() === false;

  /** Synthesize the script, register the media asset, and drop one clip on the
   * soundtrack at the playhead. */
  const generate = async () => {
    const text = script.trim();
    if (!text) return;
    setBusy(true);
    setError(null);
    try {
      const playhead = useEditor.getState().currentTime;
      const lead = text.split(/\s+/).slice(0, 4).join(" ");
      // synthesizeSpeech reads the direction for a "say it in X" ask and
      // translates the script into that language before speaking it.
      const { asset } = await synthesizeSpeech(projectId, [{ text, at: 0 }], {
        voice,
        direction,
        language,
        name: `AI voice — ${lead}`,
      });
      const cur = useEditor.getState();
      cur.addAsset(asset);
      cur.addAudioFromAsset(asset.id, playhead, {
        // New voiceovers duck everything else to the default; fine-tune on the
        // clip itself ("Duck others" in the inspector).
        duck: DUCK_DEFAULT,
      });
      void enrichAsset(asset);
    } catch (e) {
      fail(e, "Voice generation failed.");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="voice-generator flex flex-col gap-3.5">
      {/* Voice settings first — pick how the voice sounds, then script it. */}
      <VoicePicker onError={(e) => fail(e, "Could not play the sample.")} />

      <div className="flex flex-col gap-1.5">
        <div className="flex items-center gap-1">
          {sectionLabel("Voice direction")}
          <TooltipProvider>
            <Tooltip>
              <TooltipTrigger
                className="voice-direction-info grid size-4 place-items-center text-muted-foreground transition-colors hover:text-foreground"
                aria-label="About voice direction"
              >
                <Info className="size-3.5" />
              </TooltipTrigger>
              <TooltipContent side="right" className="max-w-60">
                Optional. Tell the voice how to deliver the lines — its tone, pace, and energy, or
                ask it to speak in another language.
              </TooltipContent>
            </Tooltip>
          </TooltipProvider>
        </div>
        <div className="relative">
          <textarea
            ref={directionInput}
            rows={2}
            className="voice-direction min-h-[52px] w-full resize-y rounded-lg border border-input bg-transparent py-2 pr-9 pl-2.5 text-[12.5px] leading-relaxed outline-none focus:border-ring"
            placeholder="Say warmly, like an old friend"
            value={direction}
            onChange={(e) => setDirection(e.target.value)}
          />
          <DropdownMenu>
            <DropdownMenuTrigger
              className="voice-direction-presets absolute top-1.5 right-1 grid size-7 place-items-center rounded-md text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
              aria-label="Direction presets"
            >
              <ChevronDown className="size-4" />
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end" className="w-64">
              {DIRECTION_PRESETS.map((p) => (
                <DropdownMenuItem key={p.label} onClick={() => setDirection(p.text)}>
                  <div className="flex min-w-0 flex-1 flex-col">
                    <span className="text-[12px] font-medium">{p.label}</span>
                    <span className="truncate text-[11px] text-muted-foreground">{p.text}</span>
                  </div>
                  {direction === p.text && <Check className="size-3.5 shrink-0" />}
                </DropdownMenuItem>
              ))}
              <DropdownMenuSeparator />
              <DropdownMenuItem
                onClick={() => {
                  setDirection("");
                  // The menu hands focus back to the trigger on close; take it after.
                  setTimeout(() => directionInput.current?.focus(), 0);
                }}
              >
                <span className="text-[12px] font-medium">Custom…</span>
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
      </div>

      <div className="h-px shrink-0 bg-border" />

      {/* The script and its generate button stay together so the button's job —
          and why it's disabled until there's a script — is obvious. */}
      <div className="flex flex-col gap-2">
        {sectionLabel("Script")}
        <textarea
          className="voice-script min-h-[88px] w-full resize-y rounded-lg border border-input bg-transparent px-2.5 py-2 text-[12.5px] leading-relaxed outline-none focus:border-ring"
          placeholder="What should the voice say?"
          value={script}
          onChange={(e) => setScript(e.target.value)}
        />
        <Button
          className="voice-generate w-full"
          disabled={!script.trim() || busy || signedOut}
          title={!script.trim() ? "Write a script above to generate" : undefined}
          onClick={() => void generate()}
        >
          {busy ? <Loader2 className="animate-spin" /> : <AudioLines data-icon="inline-start" />}
          Generate audio
        </Button>
      </div>

      {signedOut ? (
        <p className="voice-signin text-[11px] leading-relaxed text-muted-foreground">
          Voiceovers run on your Donkey account.{" "}
          <a className="font-medium text-blue-600 hover:underline dark:text-blue-400" href={signInUrl()}>
            Sign in
          </a>{" "}
          to continue.
        </p>
      ) : (
        error && (
          <p className="voice-error text-[11px] leading-relaxed text-red-600">
            {error.text}
            {error.credits && (
              <>
                {" "}
                <a
                  className="font-medium underline hover:no-underline"
                  href={creditsUrl()}
                  target="_blank"
                  rel="noreferrer"
                >
                  Add credits
                </a>
              </>
            )}
          </p>
        )
      )}
    </div>
  );
}

/** Tiny waveform for a row, from the asset's normalized peaks. */
function PeakStrip({ peaks }: { peaks: number[] }) {
  const BARS = 48;
  const step = Math.max(1, Math.floor(peaks.length / BARS));
  const bars: number[] = [];
  for (let i = 0; i < BARS; i++) {
    let m = 0;
    for (let j = i * step; j < Math.min(peaks.length, (i + 1) * step); j++) {
      if (peaks[j] > m) m = peaks[j];
    }
    bars.push(m);
  }
  return (
    <svg
      viewBox={`0 0 ${BARS * 2} 16`}
      preserveAspectRatio="none"
      className="mt-1 h-4 w-full text-muted-foreground/50"
      aria-hidden
    >
      {bars.map((p, i) => {
        const h = Math.max(1.5, p * 16);
        return <rect key={i} x={i * 2} y={(16 - h) / 2} width={1.2} height={h} rx={0.6} fill="currentColor" />;
      })}
    </svg>
  );
}

/** Off-screen drag image that mirrors an audio clip on the timeline — an
 * emerald pill with the name and a white waveform — so the drag reads as the
 * thing that will land, not the panel row. Lives just long enough for the
 * browser to snapshot it. */
function buildAudioDragGhost(name: string, width: number, peaks?: number[]): HTMLElement {
  const height = 40; // AUDIO_H - 4, matching a timeline audio clip.
  const el = document.createElement("div");
  el.style.cssText =
    `position:absolute;top:-1000px;left:-1000px;pointer-events:none;width:${width}px;height:${height}px;` +
    "border-radius:7px;overflow:hidden;background:linear-gradient(to bottom,#10b981,#059669);" +
    "box-shadow:inset 0 0 0 1px rgba(0,0,0,0.1),0 10px 26px rgba(0,0,0,0.35);";

  const wave = height - 8;
  const canvas = document.createElement("canvas");
  const dpr = window.devicePixelRatio || 1;
  canvas.width = Math.round(width * dpr);
  canvas.height = Math.round(wave * dpr);
  canvas.style.cssText = `position:absolute;left:0;top:4px;width:${width}px;height:${wave}px;`;
  const ctx = canvas.getContext("2d");
  if (ctx) {
    ctx.scale(dpr, dpr);
    ctx.fillStyle = "rgba(255,255,255,0.85)";
    const bars = Math.max(1, Math.floor(width / 3));
    const n = peaks?.length ?? 0;
    for (let i = 0; i < bars; i++) {
      // Use the asset's peaks when we have them; otherwise a gentle stand-in so
      // the pill still reads as audio.
      const p = n ? (peaks![Math.min(n - 1, Math.floor((i / bars) * n))] ?? 0) : 0.32 + 0.26 * Math.abs(Math.sin(i / 2));
      const h = Math.max(1.5, p * (wave - 2));
      ctx.fillRect(i * 3, (wave - h) / 2, 2, h);
    }
  }
  el.appendChild(canvas);

  const label = document.createElement("span");
  label.textContent = name;
  label.style.cssText =
    "position:absolute;top:3px;left:8px;right:8px;color:rgba(255,255,255,0.9);white-space:nowrap;" +
    "overflow:hidden;text-overflow:ellipsis;text-shadow:0 1px 2px rgba(0,0,0,0.35);" +
    "font:500 9.5px/1.2 ui-sans-serif,system-ui,sans-serif;";
  el.appendChild(label);
  return el;
}

function AudioRow({
  name,
  duration,
  url,
  peaks,
  playing,
  onTogglePlay,
  onAdd,
  onDelete,
  onDragStart,
}: {
  name: string;
  duration: number;
  url: string;
  peaks?: number[];
  playing: boolean;
  onTogglePlay: (url: string) => void;
  onAdd: () => void;
  onDelete?: () => void;
  /** Present when the row can be dragged onto the timeline. */
  onDragStart?: DragEventHandler<HTMLDivElement>;
}) {
  return (
    <div
      className="audio-row group relative flex items-center gap-2 rounded-lg border border-border p-1.5 pr-2 transition-colors hover:border-input hover:bg-muted/50"
      draggable={!!onDragStart}
      onDragStart={
        onDragStart &&
        ((e) => {
          onDragStart(e);
          // Size the ghost to the clip's on-timeline width (duration × zoom),
          // clamped so a very short or very long clip stays a sane drag image.
          const width = Math.round(
            Math.max(44, Math.min(520, duration * useEditor.getState().pxPerSec))
          );
          const ghost = buildAudioDragGhost(name, width, peaks);
          document.body.appendChild(ghost);
          e.dataTransfer.setDragImage(ghost, Math.min(20, width / 2), 20);
          setTimeout(() => ghost.remove(), 0);
        })
      }
      onDragEnd={onDragStart ? clearAssetDrag : undefined}
      title={onDragStart ? "Drag onto the timeline, or click + to add" : undefined}
    >
      <button
        type="button"
        className={cn(
          "grid size-8 shrink-0 place-items-center rounded-full text-foreground transition-colors",
          playing ? "bg-primary text-primary-foreground" : "bg-muted hover:bg-muted-foreground/20"
        )}
        title={playing ? "Pause" : "Play"}
        aria-label={playing ? "Pause" : "Play"}
        onClick={() => onTogglePlay(url)}
      >
        {playing ? <Pause className="size-3.5" /> : <Play className="size-3.5" />}
      </button>
      {/* The name and waveform run the full width; the trailing controls scrim
          over the right edge only on hover, so nothing is reserved for them. */}
      <div className="min-w-0 flex-1">
        <div className="flex items-baseline justify-between gap-2">
          <span className="truncate text-[11.5px] font-medium">{name}</span>
          <span className="shrink-0 font-mono text-[10px] text-muted-foreground tabular-nums">
            {formatTime(duration)}
          </span>
        </div>
        {peaks && peaks.length > 0 && <PeakStrip peaks={peaks} />}
      </div>
      <div className="absolute inset-y-0 right-0 flex items-center gap-1 rounded-r-lg from-card via-card bg-gradient-to-l to-transparent pr-2 pl-8 opacity-0 transition-opacity group-hover:opacity-100">
        {onDelete && (
          <button
            type="button"
            title="Remove from project"
            aria-label="Remove from project"
            className="grid size-6 shrink-0 place-items-center rounded-full text-muted-foreground transition-colors hover:bg-destructive/10 hover:text-destructive"
            onClick={onDelete}
          >
            <Trash2 className="size-3.5" />
          </button>
        )}
        <button
          type="button"
          title="Add at the playhead"
          aria-label="Add at the playhead"
          className="grid size-6 shrink-0 place-items-center rounded-full text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
          onClick={onAdd}
        >
          <Plus className="size-3.5" />
        </button>
      </div>
    </div>
  );
}

function ProjectAudio({
  importing,
  onTogglePlay,
  playingUrl,
}: {
  importing: boolean;
  onTogglePlay: (url: string) => void;
  playingUrl: string | null;
}) {
  const assets = useEditor((s) => s.assets);
  const audio = assets.filter((a) => a.type === "audio" && a.origin === "voiceover");
  return (
    <div className="flex flex-col gap-1.5">
      {sectionLabel("Generated audio")}
      {audio.length === 0 && !importing && (
        <p className="text-[11px] leading-relaxed text-muted-foreground">
          No generated audio yet — write a script above and generate one.
        </p>
      )}
      <div className="flex flex-col gap-1.5">
        {audio.map((a) => (
          <AudioRow
            key={a.id}
            name={a.name}
            duration={a.duration}
            url={a.url}
            peaks={a.peaks}
            playing={playingUrl === a.url}
            onTogglePlay={onTogglePlay}
            onAdd={() => useEditor.getState().addAudioFromAsset(a.id)}
            onDelete={() => useEditor.getState().removeAsset(a.id)}
            onDragStart={(e) => setAssetDragData(e, a.id)}
          />
        ))}
        {importing && (
          <div className="flex items-center gap-2 rounded-lg border border-dashed border-input px-2.5 py-2 text-[11px] text-muted-foreground">
            <Loader2 className="size-3.5 animate-spin" /> Importing…
          </div>
        )}
      </div>
    </div>
  );
}

function LibraryAudio({
  projectId,
  onTogglePlay,
  playingUrl,
}: {
  projectId: string;
  onTogglePlay: (url: string) => void;
  playingUrl: string | null;
}) {
  const [assets, setAssets] = useState<LibraryAsset[]>([]);
  useEffect(() => {
    let alive = true;
    fetchLibrary()
      .then((d) => alive && setAssets(d.assets.filter((a) => a.type === "audio")))
      .catch(() => {});
    return () => {
      alive = false;
    };
  }, []);
  if (assets.length === 0) return null;
  return (
    <div className="flex flex-col gap-1.5">
      {sectionLabel("Library")}
      <div className="flex flex-col gap-1.5">
        {assets.map((a) => (
          <AudioRow
            key={a.id}
            name={a.name}
            duration={a.duration}
            url={libraryMediaUrl(a.fileName)}
            playing={playingUrl === libraryMediaUrl(a.fileName)}
            onTogglePlay={onTogglePlay}
            onAdd={() => void addLibraryAssetToProject(projectId, a)}
            onDragStart={(e) => setLibraryDragData(e, a)}
          />
        ))}
      </div>
    </div>
  );
}
