"use client";

/**
 * Transcription over the engine's on-device STT (Apple SpeechAnalyzer via
 * cut-stt) — the same route (and poller) the subtitle tools use. Nothing
 * leaves the machine.
 *
 * The route transcribes a rendered mix, so we hand it a one-entry spec that
 * renders just the target audio asset: provided-mode ("animate this audio")
 * then transcribes exactly the spine the shots are cut against, not whatever
 * else is on the timeline.
 */

import { runTranscription, useEditor } from "../../store";
import { trackLocale } from "../../subtitles";
import type { TranscribeRole } from "../capabilities";
import type { TranscriptWord } from "../types";

export function makeTranscribeRole(projectId: string): TranscribeRole {
  return {
    async transcribe(audioMediaId) {
      const state = useEditor.getState();
      const asset = state.assets.find((a) => a.id === audioMediaId);
      if (!asset || asset.type !== "audio") throw new Error("No audio to transcribe.");
      const cues = await runTranscription(projectId, {
        duration: asset.duration,
        // The recognizer's language: a voiceover stamped what it speaks at
        // synthesis; imported audio falls back to the project's subtitle
        // language. The wrong recognizer romanizes the words into garbage and
        // the whole plan downstream depicts that garbage.
        locale: asset.language ?? trackLocale(state.subtitles, state.subtitleLane),
        clips: [],
        audio: [{ file: asset.fileName, in: 0, out: asset.duration, start: 0, volume: 1 }],
      });
      // The poller yields null when the project closed mid-run. That is a
      // pause, never a result — an empty transcript here would silently plan
      // shots with no relation to the narration's words.
      if (cues === null) throw new Error("Transcription stopped — the project was closed.");
      return cues.flatMap<TranscriptWord>((c) => c.words ?? []);
    },
  };
}
