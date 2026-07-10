import { enrichAsset } from "@/cut/lib/media";
import { useEditor } from "@/cut/lib/store";
import { synthesizeSpeech } from "@/cut/lib/tts";

/** Default duck: everything else drops to 40% while a voiceover speaks. */
export const DUCK_DEFAULT = 0.4;

/**
 * Voice the subtitle cues (all of them, or just `opts.cueIds`) and drop the
 * result on the soundtrack at the first cue. The spoken pace differs from the
 * original recording, so the read cues are re-timed to the generated audio —
 * keeping the word highlighter in step. Shared by the panel button and the AI
 * assistant's read_subtitles_aloud tool. Throws with a user-facing message on
 * failure.
 */
export async function generateSubtitlesReadout(
  voice: string,
  opts?: { cueIds?: string[]; direction?: string; language?: string; duck?: number }
) {
  const s = useEditor.getState();
  const projectId = s.projectId;
  if (!projectId) throw new Error("Open a project first.");
  const wanted = opts?.cueIds && new Set(opts.cueIds);
  const cues = s.subtitles.cues.filter((c) => c.text.trim() && (!wanted || wanted.has(c.id)));
  if (cues.length === 0) throw new Error("No subtitles to read.");

  const { asset, offset, layout } = await synthesizeSpeech(
    projectId,
    cues.map((c) => ({ text: c.text, at: c.start })),
    { voice, direction: opts?.direction, language: opts?.language, name: "Subtitles readout" }
  );
  const duck = opts?.duck ?? DUCK_DEFAULT;
  const cur = useEditor.getState();
  cur.addAsset(asset);
  cur.addAudioFromAsset(asset.id, offset, { duck: duck < 1 ? duck : undefined });
  if (layout.length === cues.length) {
    cur.retimeCues(
      layout.map((seg, i) => ({
        id: cues[i].id,
        start: seg.at,
        // Stop at the next line's start so re-timed captions never overlap.
        end: Math.min(seg.at + seg.duration, layout[i + 1]?.at ?? Infinity),
      }))
    );
  }
  void enrichAsset(asset);
  return { asset, start: offset, lines: cues.length, duck: duck < 1 ? duck : null };
}
