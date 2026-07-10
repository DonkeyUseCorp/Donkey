"use client";

import { importFileToProject } from "./media";
import type { MediaAsset } from "./types";

// Client side of AI voiceovers: Gemini speech generation on Donkey's hosted
// inference routes, with the user's Donkey sign-in and credits (same-origin on
// the cut hosts, like image/video generation). Each segment comes back as raw
// PCM; the browser lays the segments out at their timeline offsets, encodes
// one WAV, and saves it into the project through the local engine like any
// other media file.

export interface SpeechVoice {
  id: string;
  /** One-word character from the voice catalog ("Warm", "Upbeat"). */
  style: string;
}

export interface SpeechSegment {
  text: string;
  /** Timeline offset this line should land at, seconds. */
  at: number;
}

/** Gemini's prebuilt voices. The set is fixed by the model, so it ships
 * hardcoded — no listing round-trip. */
export const SPEECH_VOICES: SpeechVoice[] = [
  { id: "Zephyr", style: "Bright" },
  { id: "Puck", style: "Upbeat" },
  { id: "Charon", style: "Informative" },
  { id: "Kore", style: "Firm" },
  { id: "Fenrir", style: "Excitable" },
  { id: "Leda", style: "Youthful" },
  { id: "Orus", style: "Firm" },
  { id: "Aoede", style: "Breezy" },
  { id: "Callirrhoe", style: "Easy-going" },
  { id: "Autonoe", style: "Bright" },
  { id: "Enceladus", style: "Breathy" },
  { id: "Iapetus", style: "Clear" },
  { id: "Umbriel", style: "Easy-going" },
  { id: "Algieba", style: "Smooth" },
  { id: "Despina", style: "Smooth" },
  { id: "Erinome", style: "Clear" },
  { id: "Algenib", style: "Gravelly" },
  { id: "Rasalgethi", style: "Informative" },
  { id: "Laomedeia", style: "Upbeat" },
  { id: "Achernar", style: "Soft" },
  { id: "Alnilam", style: "Firm" },
  { id: "Schedar", style: "Even" },
  { id: "Gacrux", style: "Mature" },
  { id: "Pulcherrima", style: "Forward" },
  { id: "Achird", style: "Friendly" },
  { id: "Zubenelgenubi", style: "Casual" },
  { id: "Vindemiatrix", style: "Gentle" },
  { id: "Sadachbia", style: "Lively" },
  { id: "Sadaltager", style: "Knowledgeable" },
  { id: "Sulafat", style: "Warm" },
];

export const DEFAULT_VOICE = "Puck";

export interface SpeechLanguage {
  id: string;
  label: string;
  /** Voice-picker sample line, written natively in the language. */
  sample: string;
}

// Sample lines stay full declarative sentences — "Hey!"-style leads make the
// TTS model intermittently return an empty clip. Change with care and re-check
// reliability across voices.
const SAMPLE_TEXT = "This is how I sound. Let's make something worth remembering.";

/** Languages the speech model speaks (BCP-47, fixed by the model). "auto" lets
 * the model match the text; a concrete pick pins pronunciation and picks the
 * sample line's language. */
export const SPEECH_LANGUAGES: SpeechLanguage[] = [
  { id: "auto", label: "Auto — match the text", sample: SAMPLE_TEXT },
  { id: "ar-EG", label: "Arabic", sample: "هذا هو صوتي. لنصنع شيئًا يستحق التذكر." },
  { id: "bn-BD", label: "Bengali", sample: "আমার কণ্ঠ এমনই শোনায়। চলুন মনে রাখার মতো কিছু তৈরি করি।" },
  { id: "nl-NL", label: "Dutch", sample: "Zo klink ik. Laten we iets maken dat het onthouden waard is." },
  { id: "en-US", label: "English", sample: SAMPLE_TEXT },
  { id: "en-IN", label: "English (India)", sample: SAMPLE_TEXT },
  { id: "fr-FR", label: "French", sample: "Voici comment je sonne. Créons quelque chose d'inoubliable." },
  { id: "de-DE", label: "German", sample: "So klinge ich. Lass uns etwas Unvergessliches schaffen." },
  { id: "hi-IN", label: "Hindi", sample: "मेरी आवाज़ ऐसी है। चलिए कुछ यादगार बनाते हैं।" },
  { id: "id-ID", label: "Indonesian", sample: "Seperti inilah suara saya. Mari membuat sesuatu yang layak dikenang." },
  { id: "it-IT", label: "Italian", sample: "Questa è la mia voce. Creiamo qualcosa che valga la pena ricordare." },
  { id: "ja-JP", label: "Japanese", sample: "これが私の声です。記憶に残るものを作りましょう。" },
  { id: "ko-KR", label: "Korean", sample: "제 목소리는 이렇습니다. 기억에 남을 만한 것을 만들어 봅시다." },
  { id: "mr-IN", label: "Marathi", sample: "माझा आवाज असा आहे. चला काहीतरी संस्मरणीय बनवूया." },
  { id: "pl-PL", label: "Polish", sample: "Tak brzmi mój głos. Stwórzmy coś wartego zapamiętania." },
  { id: "pt-BR", label: "Portuguese", sample: "Esta é a minha voz. Vamos criar algo que valha a pena lembrar." },
  { id: "ro-RO", label: "Romanian", sample: "Așa sună vocea mea. Să creăm ceva demn de amintit." },
  { id: "ru-RU", label: "Russian", sample: "Вот как звучит мой голос. Давайте создадим что-то запоминающееся." },
  { id: "es-US", label: "Spanish", sample: "Así sueno. Hagamos algo digno de recordar." },
  { id: "ta-IN", label: "Tamil", sample: "என் குரல் இப்படித்தான் ஒலிக்கிறது. நினைவில் நிற்கும் ஒன்றை உருவாக்குவோம்." },
  { id: "te-IN", label: "Telugu", sample: "నా గొంతు ఇలా వినిపిస్తుంది. గుర్తుండిపోయేది ఒకటి చేద్దాం." },
  { id: "th-TH", label: "Thai", sample: "เสียงของฉันเป็นแบบนี้ มาสร้างสิ่งที่น่าจดจำกันเถอะ" },
  { id: "tr-TR", label: "Turkish", sample: "Sesim böyle. Hatırlanmaya değer bir şey yapalım." },
  { id: "uk-UA", label: "Ukrainian", sample: "Ось як звучить мій голос. Створімо щось варте пам'яті." },
  { id: "vi-VN", label: "Vietnamese", sample: "Giọng của tôi nghe như thế này. Hãy cùng tạo nên điều gì đó đáng nhớ." },
];

export const DEFAULT_LANGUAGE = "auto";

/** Resolve a requested speech language against the catalog: an exact
 * (case-insensitive) BCP-47 match, else a bare language ("es") to its catalog
 * variant, else auto-detect. Shared by every generation surface and the AI
 * copilot so a loose ask still lands on a supported code. */
export function resolveLanguage(wanted?: string): string {
  const w = wanted?.trim().toLowerCase();
  if (!w || w === "auto") return DEFAULT_LANGUAGE;
  const exact = SPEECH_LANGUAGES.find((l) => l.id.toLowerCase() === w);
  if (exact) return exact.id;
  const bare = SPEECH_LANGUAGES.find((l) => l.id.toLowerCase().startsWith(`${w}-`));
  return bare?.id ?? DEFAULT_LANGUAGE;
}

/** Resolve a requested voice against the catalog: an exact (or
 * case-insensitive) id match, else the default. Shared by the Audio panel and
 * the AI copilot so both land on the same voice. */
export function resolveVoice(wanted?: string): string {
  if (typeof wanted === "string" && wanted.trim()) {
    const exact = SPEECH_VOICES.find((v) => v.id === wanted.trim());
    if (exact) return exact.id;
    const ci = SPEECH_VOICES.find(
      (v) => v.id.toLowerCase() === wanted.trim().toLowerCase()
    );
    if (ci) return ci.id;
  }
  return DEFAULT_VOICE;
}

const CLIENT_ID = "donkey-cut";
const MAX_SEGMENTS = 200;
const MAX_SEGMENT_CHARS = 2000;
const MAX_TOTAL_CHARS = 20000;
/** Hosted synthesis calls in flight at once for multi-line readouts. */
const CONCURRENCY = 3;

interface PcmClip {
  samples: Int16Array;
  rate: number;
}

/** The account balance can't cover the generation — callers surface a link to
 * buy credits alongside the message. */
export class NoCreditsError extends Error {}

async function readError(res: Response, fallback: string): Promise<string> {
  if (res.status === 401) return "Sign in to Donkey to generate voiceovers.";
  const body = (await res.json().catch(() => null)) as {
    error?: unknown;
    message?: unknown;
    details?: { message?: unknown };
  } | null;
  const message = [body?.message, body?.error].find(
    (v): v is string => typeof v === "string" && v.length > 0
  );
  if (res.status === 402) return message ?? "Not enough Donkey credits — top up to continue.";
  // The provider's own error (`details.message`) names the actual rejection
  // ("input too long", a rate limit, …); the top-level message is generic.
  const detail = body?.details?.message;
  const full =
    message && typeof detail === "string" && detail && detail !== message
      ? `${message} (${detail})`
      : message;
  return full ?? fallback;
}

/** One hosted Gemini speech call: text in, decoded PCM out. A direction is a
 * natural-language delivery instruction ("Say warmly, like an old friend");
 * the model also honors inline tags like [whispers] in the text itself. */
async function synthesizeSegment(
  text: string,
  voice: string,
  direction?: string,
  language?: string
): Promise<PcmClip> {
  const style = direction?.trim();
  const languageCode = resolveLanguage(language);
  const res = await fetch("/api/inference/assets", {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-donkey-client-id": CLIENT_ID },
    body: JSON.stringify({
      kind: "speech",
      prompt: style ? `${style}: ${text}` : text,
      inputs: { voice },
      ...(languageCode !== DEFAULT_LANGUAGE
        ? { parameters: { languageCode } }
        : {}),
    }),
  });
  if (!res.ok) {
    const message = await readError(res, "Voice generation failed.");
    throw res.status === 402 ? new NoCreditsError(message) : new Error(message);
  }
  const gen = (await res.json()) as {
    outputs?: { dataBase64?: string; contentType?: string }[];
  };
  const out = gen.outputs?.find((o) => o.dataBase64);
  if (!out?.dataBase64) throw new Error("The provider returned no audio.");

  const bin = atob(out.dataBase64);
  const bytes = new Uint8Array(new ArrayBuffer(bin.length));
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  const rate = Number(out.contentType?.match(/rate=(\d+)/)?.[1]) || 24000;
  // Gemini TTS returns raw little-endian 16-bit mono PCM.
  return { samples: new Int16Array(bytes.buffer, 0, bytes.byteLength >> 1), rate };
}

/** Nearest-neighbor resample, only for the off chance segments disagree. */
function resample(clip: PcmClip, rate: number): PcmClip {
  if (clip.rate === rate) return clip;
  const out = new Int16Array(Math.round((clip.samples.length * rate) / clip.rate));
  for (let i = 0; i < out.length; i++) {
    out[i] = clip.samples[Math.min(clip.samples.length - 1, Math.round((i * clip.rate) / rate))];
  }
  return { samples: out, rate };
}

/** Lay the clips out at their offsets (summing any overlap, clamped) and wrap
 * the result in a WAV container. */
function assembleWav(clips: PcmClip[], offsets: number[]): Blob {
  const rate = clips[0].rate;
  const aligned = clips.map((c) => resample(c, rate));
  const starts = offsets.map((o) => Math.round(o * rate));
  const total = Math.max(...aligned.map((c, i) => starts[i] + c.samples.length));

  const mix = new Int32Array(total);
  aligned.forEach((c, i) => {
    const from = starts[i];
    for (let j = 0; j < c.samples.length; j++) mix[from + j] += c.samples[j];
  });

  const data = new Int16Array(total);
  for (let i = 0; i < total; i++) {
    data[i] = Math.max(-32768, Math.min(32767, mix[i]));
  }

  const header = new DataView(new ArrayBuffer(44));
  const write = (at: number, s: string) => {
    for (let i = 0; i < s.length; i++) header.setUint8(at + i, s.charCodeAt(i));
  };
  write(0, "RIFF");
  header.setUint32(4, 36 + data.byteLength, true);
  write(8, "WAVE");
  write(12, "fmt ");
  header.setUint32(16, 16, true);
  header.setUint16(20, 1, true); // PCM
  header.setUint16(22, 1, true); // mono
  header.setUint32(24, rate, true);
  header.setUint32(28, rate * 2, true);
  header.setUint16(32, 2, true);
  header.setUint16(34, 16, true);
  write(36, "data");
  header.setUint32(40, data.byteLength, true);
  return new Blob([header.buffer, data.buffer], { type: "audio/wav" });
}

/**
 * Synthesize segments into one WAV in the project's media folder. The file's
 * t=0 is the earliest segment, and `offset` is that earliest timeline time —
 * drop one audio clip at `offset` and every line lands on its cue.
 */
export interface SpeechLayout {
  /** The input segment's text, so callers can match a line back to its cue. */
  text: string;
  /** Timeline second this line's audio starts at. */
  at: number;
  /** How long the generated audio for this line runs, seconds. */
  duration: number;
}

export async function synthesizeSpeech(
  projectId: string,
  segments: SpeechSegment[],
  opts: { voice: string; direction?: string; language?: string; name?: string }
): Promise<{ asset: MediaAsset; offset: number; layout: SpeechLayout[] }> {
  const lines = segments
    .map((s) => ({ text: s.text.trim(), at: Math.max(0, s.at) }))
    .filter((s) => s.text);
  if (lines.length === 0) throw new Error("Nothing to say.");
  if (lines.length > MAX_SEGMENTS) throw new Error(`At most ${MAX_SEGMENTS} lines at once.`);
  if (lines.some((s) => s.text.length > MAX_SEGMENT_CHARS)) {
    throw new Error(`Each line must stay under ${MAX_SEGMENT_CHARS} characters.`);
  }
  if (lines.reduce((n, s) => n + s.text.length, 0) > MAX_TOTAL_CHARS) {
    throw new Error(`The script must stay under ${MAX_TOTAL_CHARS} characters.`);
  }

  const offset = Math.min(...lines.map((s) => s.at));
  const voice = resolveVoice(opts.voice);

  // A small pool: readouts can be dozens of lines, one hosted call each.
  const clips: PcmClip[] = new Array(lines.length);
  let next = 0;
  const worker = async () => {
    while (next < lines.length) {
      const i = next++;
      try {
        try {
          clips[i] = await synthesizeSegment(lines[i].text, voice, opts.direction, opts.language);
        } catch (e) {
          // An empty balance repeats forever — resending only burns the queue.
          if (e instanceof NoCreditsError) throw e;
          // The TTS backend rejects the odd call spuriously; one resend of just
          // this line usually lands and saves the rest of the batch.
          clips[i] = await synthesizeSegment(lines[i].text, voice, opts.direction, opts.language);
        }
      } catch (e) {
        // Name the line that failed so a one-bad-cue batch is actionable.
        if (lines.length > 1 && e instanceof Error && !(e instanceof NoCreditsError)) {
          const snippet = lines[i].text.length > 40 ? `${lines[i].text.slice(0, 40)}…` : lines[i].text;
          throw new Error(`Line ${i + 1} ("${snippet}"): ${e.message}`);
        }
        throw e;
      }
    }
  };
  await Promise.all(
    Array.from({ length: Math.min(CONCURRENCY, lines.length) }, worker)
  );

  // Each line lands at its cue offset — unless the previous line's speech runs
  // past it. The generated pace differs from the original recording, so such
  // overlaps are common; mixed as-is they'd play two voice lines at once. The
  // pushed-back starts are reported in `layout` so callers re-time their cues.
  const placed: number[] = [];
  let cursor = 0;
  lines.forEach((l, i) => {
    const at = Math.max(l.at - offset, cursor);
    placed.push(at);
    cursor = at + clips[i].samples.length / clips[i].rate;
  });

  const wav = assembleWav(clips, placed);
  const name = opts.name?.trim() || "AI voice";
  const file = new File([wav], `${slug(name)}.wav`, { type: "audio/wav" });
  const asset = await importFileToProject(projectId, file);
  if (!asset) throw new Error("Could not save the voiceover into the project.");
  asset.name = name;
  asset.origin = "voiceover";
  // Report where each line's audio actually lands and how long it runs, so a
  // subtitles readout can re-time its cues to the generated voice (whose pace
  // differs from the original recording).
  const layout: SpeechLayout[] = lines.map((l, i) => ({
    text: l.text,
    at: offset + placed[i],
    duration: clips[i].samples.length / clips[i].rate,
  }));
  return { asset, offset, layout };
}

/** A short spoken sample for the voice picker, in the picked language. Each
 * voice+language pair is synthesized once per session and cached as a blob URL. */
const samples = new Map<string, string>();

export async function speechSampleUrl(voice: string, language?: string): Promise<string> {
  const id = resolveVoice(voice);
  const lang = resolveLanguage(language);
  const key = `${id}|${lang}`;
  const cached = samples.get(key);
  if (cached) return cached;
  const text = SPEECH_LANGUAGES.find((l) => l.id === lang)?.sample ?? SAMPLE_TEXT;
  const clip = await synthesizeSegment(text, id, undefined, lang);
  const url = URL.createObjectURL(assembleWav([clip], [0]));
  samples.set(key, url);
  return url;
}

function slug(name: string) {
  return (
    name
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .slice(0, 40) || "ai-voice"
  );
}
