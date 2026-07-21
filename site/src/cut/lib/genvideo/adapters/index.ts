"use client";

/**
 * The real model suite: every genvideo role bound to Donkey's hosted models,
 * built for one open project. This is the production counterpart to
 * `fakeRegistry()` — the orchestrator depends only on the role interfaces, so
 * swapping fakes for this is the whole wiring.
 *
 * It lives here, not in `registry.ts`, so `registry.ts` stays free of the
 * browser-only generation modules and the node self-test can keep importing the
 * fakes from it.
 *
 * No `lipSync` role: there is no hosted lip-sync, and `video.audioNative` is
 * false, so a provided-audio scene places each shot as muted b-roll under the
 * user's spine, while a generated scene lets each shot's burned-in narration
 * play. `music` is always present but best-effort — it degrades to no bed when
 * no music backend is configured. `review` is the dailies check: every take is
 * watched against its plan before it places.
 */

import type { ModelSuite } from "../capabilities";
import { makeImageRole, makeVideoRole, makeVoiceRole } from "./media";
import { makeMusicRole } from "./music";
import { makeReviewRole } from "./review";
import { makeBreakdownRole, makeScriptRole, makeStyleRole } from "./text";
import { makeTranscribeRole } from "./transcribe";

/** Build the suite for one project. `chatId` is the owning chat thread — every
 * asset the run creates is tagged to it (via the adapters) so the intermediates
 * and shots stay off the Media/Video/Image/Audio panels, exactly like the
 * single-asset chat generation tools. */
export function realSuite(projectId: string, chatId?: string): ModelSuite {
  return {
    label: "donkey-hosted",
    script: makeScriptRole(),
    breakdown: makeBreakdownRole(),
    style: makeStyleRole(projectId),
    image: makeImageRole(projectId, chatId),
    video: makeVideoRole(projectId, chatId),
    voice: makeVoiceRole(projectId, chatId),
    music: makeMusicRole(projectId, chatId),
    transcribe: makeTranscribeRole(projectId),
    review: makeReviewRole(projectId),
  };
}
