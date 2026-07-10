"use client";

import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { Captions, ChevronDown, Languages, Loader2, Pause, Play } from "lucide-react";
import { Button } from "@/components/ui/button";
import { creditsUrl, signInUrl, useSignedIn } from "@/cut/lib/generate";
import { useEditor } from "@/cut/lib/store";
import {
  NoCreditsError,
  resolveLanguage,
  resolveVoice,
  speechSampleUrl,
  SPEECH_LANGUAGES,
  SPEECH_VOICES,
} from "@/cut/lib/tts";
import { generateSubtitlesReadout, previewSubtitlesReadout } from "@/cut/lib/voiceover";

// Shared speech preferences (speaker voice, spoken language) for every surface
// that generates audio (Audio tab, Subtitles tab, clip settings). Module-level
// so all mounted pickers stay in sync; persisted so they survive reloads.
function preference(key: string, resolve: (wanted?: string) => string) {
  let current: string | null = null;
  const listeners = new Set<() => void>();
  return {
    read(): string {
      if (current === null) {
        current = resolve(
          typeof window === "undefined" ? undefined : (localStorage.getItem(key) ?? undefined)
        );
      }
      return current;
    },
    write(id: string) {
      current = resolve(id);
      try {
        localStorage.setItem(key, current);
      } catch {
        // Preference only.
      }
      listeners.forEach((l) => l());
    },
    subscribe(l: () => void) {
      listeners.add(l);
      return () => {
        listeners.delete(l);
      };
    },
  };
}

const voicePref = preference("cut-tts-voice", resolveVoice);
const languagePref = preference("cut-tts-language", resolveLanguage);

/** The shared speaker voice; every generation surface reads this. */
export function useSpeakerVoice(): string {
  return useSyncExternalStore(voicePref.subscribe, voicePref.read, () => resolveVoice(undefined));
}

/** The shared spoken language ("auto" = match the text); every generation
 * surface reads this. */
export function useSpeechLanguage(): string {
  return useSyncExternalStore(languagePref.subscribe, languagePref.read, () =>
    resolveLanguage(undefined)
  );
}

/**
 * Speaker-voice row: a play button that samples the voice plus the voice
 * select. Drop it into any surface that generates speech — they all share one
 * persisted voice choice. Pass `sample` to make the play button preview real
 * content (e.g. the subtitle readout) instead of the canned voice sample.
 */
export function VoicePicker({
  onError,
  title = "Speaker voice",
  sample: sampleOverride,
}: {
  onError?: (e: unknown) => void;
  title?: string;
  sample?: { run: () => Promise<string>; title?: string; disabled?: boolean };
}) {
  const voice = useSpeakerVoice();
  const language = useSpeechLanguage();
  const signedOut = useSignedIn() === false;
  const [sampling, setSampling] = useState<null | "loading" | "playing">(null);
  const sampler = useRef<HTMLAudioElement | null>(null);
  const sampleSeq = useRef(0);

  useEffect(
    () => () => {
      sampler.current?.pause();
    },
    []
  );

  const play = () => {
    const el = (sampler.current ??= new Audio());
    if (sampling) {
      sampleSeq.current++;
      el.pause();
      setSampling(null);
      return;
    }
    const seq = ++sampleSeq.current;
    setSampling("loading");
    (sampleOverride?.run ?? (() => speechSampleUrl(voice, language)))()
      .then((url) => {
        if (seq !== sampleSeq.current) return;
        el.src = url;
        el.onended = () => setSampling(null);
        el.onerror = () => setSampling(null);
        setSampling("playing");
        return el.play();
      })
      .catch((e: unknown) => {
        if (seq !== sampleSeq.current) return;
        setSampling(null);
        onError?.(e);
      });
  };

  const sampleTitle = sampleOverride?.title ?? "Hear this voice";

  return (
    <div className="voice-picker flex flex-col gap-1.5">
      <span className="text-[11px] font-semibold tracking-wider text-muted-foreground uppercase">
        {title}
      </span>
      <div className="flex items-center gap-2">
        <button
          type="button"
          className="voice-sample grid size-8 shrink-0 place-items-center rounded-full bg-muted text-foreground transition-colors hover:bg-muted-foreground/20 disabled:opacity-40"
          title={sampleTitle}
          aria-label={sampleTitle}
          disabled={signedOut || sampleOverride?.disabled === true}
          onClick={play}
        >
          {sampling === "loading" ? (
            <Loader2 className="size-3.5 animate-spin" />
          ) : sampling === "playing" ? (
            <Pause className="size-3.5" />
          ) : (
            <Play className="size-3.5" />
          )}
        </button>
        <div className="relative min-w-0 flex-1">
          <select
            className="voice-select w-full appearance-none truncate rounded-lg border border-input bg-transparent py-2 pr-8 pl-2.5 text-[12.5px] outline-none focus:border-ring"
            value={voice}
            onChange={(e) => voicePref.write(e.target.value)}
          >
            {SPEECH_VOICES.map((v) => (
              <option key={v.id} value={v.id}>
                {v.id} · {v.style}
              </option>
            ))}
          </select>
          <ChevronDown className="pointer-events-none absolute top-1/2 right-2.5 size-4 -translate-y-1/2 text-muted-foreground" />
        </div>
      </div>
      <label
        className="voice-language-field relative ml-10 inline-flex max-w-[calc(100%-2.5rem)] items-center gap-2 self-start rounded-full border border-input py-1 pr-2.5 pl-3 text-muted-foreground transition-colors focus-within:border-ring"
        title="Spoken language"
      >
        <Languages className="size-3.5 shrink-0" />
        <span className="relative inline-flex min-w-0 items-center">
          <select
            className="voice-language max-w-full appearance-none truncate bg-transparent pr-5 text-[12.5px] text-foreground outline-none"
            value={language}
            onChange={(e) => languagePref.write(e.target.value)}
          >
            {SPEECH_LANGUAGES.map((l) => (
              <option key={l.id} value={l.id}>
                {l.label}
              </option>
            ))}
          </select>
          <ChevronDown className="pointer-events-none absolute top-1/2 right-0 size-3.5 -translate-y-1/2" />
        </span>
      </label>
      {language !== "auto" && (
        <p className="voice-language-hint text-[11px] leading-relaxed text-muted-foreground">
          {`The voice reads your script as written — write it in ${languageLabel(language)} for ${languageLabel(language)} audio.`}
        </p>
      )}
    </div>
  );
}

/** Display name for a resolved language code, for the pronunciation hint. */
function languageLabel(code: string): string {
  return SPEECH_LANGUAGES.find((l) => l.id === code)?.label ?? code;
}

/**
 * Self-contained "voice the subtitles" block: the voice picker plus a generate
 * button and its error line. `cueIds` scopes the readout (e.g. the cues inside
 * one clip); absent = every cue.
 */
export function GenerateSubtitlesAudio({
  cueIds,
  label = "Generate audio for subtitles",
}: {
  cueIds?: string[];
  label?: string;
}) {
  const voice = useSpeakerVoice();
  const language = useSpeechLanguage();
  const signedOut = useSignedIn() === false;
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<{ text: string; credits?: boolean } | null>(null);
  const wanted = cueIds && new Set(cueIds);
  const cueCount = useEditor(
    (s) => s.subtitles.cues.filter((c) => c.text.trim() && (!wanted || wanted.has(c.id))).length
  );

  const generate = async () => {
    setBusy(true);
    setError(null);
    try {
      await generateSubtitlesReadout(voice, { cueIds, language });
    } catch (e) {
      setError(
        e instanceof Error
          ? { text: e.message, credits: e instanceof NoCreditsError }
          : { text: "Voice generation failed." }
      );
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="subtitles-audio flex flex-col gap-2.5">
      <VoicePicker
        title="Generated audio"
        // Play previews the subtitle readout itself; Generate commits it. The
        // preview is cached, so committing afterward reuses the same audio.
        sample={{
          run: () => previewSubtitlesReadout(voice, { cueIds, language }),
          title: "Play the subtitles",
          disabled: cueCount === 0,
        }}
        onError={(e) => setError({ text: e instanceof Error ? e.message : "Could not play the subtitles.", credits: e instanceof NoCreditsError })}
      />
      <Button
        variant="outline"
        className="voice-readout w-full"
        disabled={cueCount === 0 || busy || signedOut}
        title={cueCount === 0 ? "Generate subtitles first" : "Voice the subtitle text and drop it on the soundtrack"}
        onClick={() => void generate()}
      >
        {busy ? <Loader2 className="animate-spin" /> : <Captions data-icon="inline-start" />}
        {label}
      </Button>
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
