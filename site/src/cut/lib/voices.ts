// Speech persona catalog: the fixed set of prebuilt voices the speech model
// offers, plus the hosted-asset URLs the picker shows. Shared by the client
// (voice picker, AI copilot) and the build script that renders each persona's
// portrait and sample clip. Dependency-light on purpose — no browser or server
// imports — so scripts/generate-voices.ts can import it directly.

export interface SpeechVoice {
  /** The model's own voice identifier (a star/mythology name like
   * "Zubenelgenubi"). The API and the hosted asset filenames key off this; it
   * is never shown to the user. */
  id: string;
  /** Friendly, memorable display name shown everywhere in the UI. */
  name: string;
  /** One-word character from the voice catalog ("Warm", "Upbeat"). */
  style: string;
  /** Apparent gender of the voice, used to group the picker (women first). */
  gender: "f" | "m";
}

/** Gemini's prebuilt voices, women first then men (the picker groups by
 * gender). The set is fixed by the model, so it ships hardcoded — no listing
 * round-trip. Each carries a plain display `name` (the raw `id` is
 * unpronounceable and unmemorable) matched to the persona's look. */
export const SPEECH_VOICES: SpeechVoice[] = [
  // Women
  { id: "Zephyr", name: "Zoe", style: "Bright", gender: "f" },
  { id: "Kore", name: "Kate", style: "Firm", gender: "f" },
  { id: "Fenrir", name: "Fiona", style: "Excitable", gender: "f" },
  { id: "Leda", name: "Lily", style: "Youthful", gender: "f" },
  { id: "Aoede", name: "Ava", style: "Breezy", gender: "f" },
  { id: "Callirrhoe", name: "Callie", style: "Easy-going", gender: "f" },
  { id: "Autonoe", name: "Nora", style: "Bright", gender: "f" },
  { id: "Despina", name: "Daphne", style: "Smooth", gender: "f" },
  { id: "Erinome", name: "Erin", style: "Clear", gender: "f" },
  { id: "Laomedeia", name: "Layla", style: "Upbeat", gender: "f" },
  { id: "Achernar", name: "Aria", style: "Soft", gender: "f" },
  { id: "Gacrux", name: "Grace", style: "Mature", gender: "f" },
  { id: "Pulcherrima", name: "Piper", style: "Forward", gender: "f" },
  { id: "Vindemiatrix", name: "Vivian", style: "Gentle", gender: "f" },
  { id: "Sadachbia", name: "Sadie", style: "Lively", gender: "f" },
  { id: "Sulafat", name: "Sofia", style: "Warm", gender: "f" },
  // Men
  { id: "Puck", name: "Max", style: "Upbeat", gender: "m" },
  { id: "Charon", name: "Charlie", style: "Informative", gender: "m" },
  { id: "Orus", name: "Oscar", style: "Firm", gender: "m" },
  { id: "Enceladus", name: "Ellis", style: "Breathy", gender: "m" },
  { id: "Iapetus", name: "Ian", style: "Clear", gender: "m" },
  { id: "Umbriel", name: "Milo", style: "Easy-going", gender: "m" },
  { id: "Algieba", name: "Andre", style: "Smooth", gender: "m" },
  { id: "Algenib", name: "Gus", style: "Gravelly", gender: "m" },
  { id: "Rasalgethi", name: "Russell", style: "Informative", gender: "m" },
  { id: "Alnilam", name: "Neil", style: "Firm", gender: "m" },
  { id: "Schedar", name: "Seth", style: "Even", gender: "m" },
  { id: "Achird", name: "Archie", style: "Friendly", gender: "m" },
  { id: "Zubenelgenubi", name: "Zane", style: "Casual", gender: "m" },
  { id: "Sadaltager", name: "Simon", style: "Knowledgeable", gender: "m" },
];

export const DEFAULT_VOICE = "Puck";

// The line every persona speaks for its hover preview and that the build script
// renders to a hosted clip. Full declarative sentences only — "Hey!"-style
// leads make the TTS model intermittently return an empty clip. Change with
// care, then re-render the samples (scripts/generate-voices.ts).
export const VOICE_SAMPLE_TEXT =
  "This is how I sound. Let's make something worth remembering.";

/** Resolve a requested voice to its model id: an exact id match, else a
 * case-insensitive match on the id or the friendly display name, else the
 * default. Shared by the picker, the AI copilot (which sees display names), and
 * the asset-URL helpers so a loose ask still lands on a real voice. */
export function resolveVoice(wanted?: string): string {
  const w = wanted?.trim();
  if (w) {
    const exact = SPEECH_VOICES.find((v) => v.id === w);
    if (exact) return exact.id;
    const ci = SPEECH_VOICES.find(
      (v) => v.id.toLowerCase() === w.toLowerCase() || v.name.toLowerCase() === w.toLowerCase()
    );
    if (ci) return ci.id;
  }
  return DEFAULT_VOICE;
}

/** Where the persona's assets live, served statically from `public/`. Both are
 * rendered once by scripts/generate-voices.ts and committed. */
const VOICE_ASSET_DIR = "/cut/voices";

/** Hosted persona portrait (square WebP). */
export function voicePortraitUrl(id: string): string {
  return `${VOICE_ASSET_DIR}/${resolveVoice(id).toLowerCase()}.webp`;
}

/** Hosted sample clip (MP3) of the persona speaking VOICE_SAMPLE_TEXT. */
export function voiceSampleUrl(id: string): string {
  return `${VOICE_ASSET_DIR}/${resolveVoice(id).toLowerCase()}.mp3`;
}
