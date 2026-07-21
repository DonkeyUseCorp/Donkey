/**
 * Brief-to-video self-test — proves the timeline math and the coverage
 * invariant with fake models before any real generation is wired, and locks in
 * a regression check for every bug the xhigh code review surfaced.
 *
 *   node_modules/.bin/bun run scripts/genvideo-selftest.ts
 */

import type { AssetRef } from "../src/cut/lib/assetRef";
import { assertCoverage, MAX_SHOT_SEC, MIN_SHOT_SEC, repairCoverage } from "../src/cut/lib/genvideo/coverage";
import { FakeEditor, type PlacedClip } from "../src/cut/lib/genvideo/editor";
import { fillSlot } from "../src/cut/lib/genvideo/fillSlot";
import { fakeSuite, type FakeStudioOptions } from "../src/cut/lib/genvideo/fakes";
import { fakeRegistry } from "../src/cut/lib/genvideo/registry";
import { VIDEO_ATTEMPTS, VideoOrchestrator, type OrchestratorDeps } from "../src/cut/lib/genvideo/orchestrator";
import { anchorRefused, buildShotAttempts } from "../src/cut/lib/genvideo/shotAttempts";
import type { RefAsset, VideoEvent, VideoProject } from "../src/cut/lib/genvideo/types";
import { walkLadder } from "../src/cut/lib/videoLadder";

let failures = 0;
function check(name: string, cond: boolean, detail = ""): void {
  if (cond) console.log(`  ✓ ${name}`);
  else {
    failures++;
    console.log(`  ✗ ${name}${detail ? ` — ${detail}` : ""}`);
  }
}
function section(title: string): void {
  console.log(`\n${title}`);
}

const FPS = 30;
const DURATION_FRAMES = 47 * FPS;

function baseProject(over: Partial<VideoProject>): VideoProject {
  return {
    id: "video:test",
    brief: "",
    references: [],
    audioMode: "provided",
    fps: FPS,
    durationFrames: 0,
    transcript: [],
    style: "",
    suiteLabel: "fake",
    characters: [],
    locations: [],
    shots: [],
    phase: "ingest",
    breakdownApproved: false,
    createdAt: 0,
    updatedAt: 0,
    ...over,
  };
}
function generatedProject(over: Partial<VideoProject> = {}): VideoProject {
  return baseProject({
    audioMode: "generated",
    brief: "a video of me and my son at the beach, cinematic",
    references: [{ mediaId: "ref:me", kind: "image", purpose: "character", name: "me" }],
    targetSeconds: 30,
    ...over,
  });
}
function editorWithAudio(durationFrames: number): FakeEditor {
  return new FakeEditor({ fps: FPS, durationFrames, aspect: "9:16" }, [
    { clipId: "audio-clip", assetId: "audio-asset", startFrame: 0, durationFrames },
  ]);
}
function emptyEditor(): FakeEditor {
  return new FakeEditor({ fps: FPS, durationFrames: 0, aspect: "9:16" }, []);
}
function deps(editor: FakeEditor, opts: FakeStudioOptions, extra: Partial<OrchestratorDeps> = {}) {
  const { suite, studio } = fakeSuite(opts);
  const events: VideoEvent[] = [];
  const d: OrchestratorDeps = { editor, suite, emit: (e) => events.push(e), persist: () => {}, sleep: async () => {}, ...extra };
  return { d, studio, events };
}
function coverageHolds(shots: { id: string; startFrame: number; endFrame: number }[], durationFrames: number): boolean {
  try {
    assertCoverage(shots as never, durationFrames);
    return true;
  } catch {
    return false;
  }
}
function assertTiling(name: string, clips: PlacedClip[], durationFrames: number): void {
  const sorted = [...clips].sort((a, b) => a.startFrame - b.startFrame);
  let ok = sorted.length > 0 && sorted[0].startFrame === 0;
  let covered = 0;
  for (let i = 0; i < sorted.length; i++) {
    if (sorted[i].endFrame <= sorted[i].startFrame) ok = false;
    if (i > 0 && sorted[i].startFrame !== sorted[i - 1].endFrame) ok = false;
    covered += sorted[i].endFrame - sorted[i].startFrame;
  }
  const last = sorted[sorted.length - 1];
  ok = ok && !!last && last.endFrame === durationFrames && covered === durationFrames;
  check(name, ok, ok ? "" : `covered ${covered}/${durationFrames} across ${sorted.length} clips`);
}
function tiles(editor: FakeEditor, durationFrames: number): boolean {
  const sorted = editor.timeline_clips();
  if (sorted.length === 0 || sorted[0].startFrame !== 0) return false;
  for (let i = 1; i < sorted.length; i++) if (sorted[i].startFrame !== sorted[i - 1].endFrame) return false;
  return sorted[sorted.length - 1].endFrame === durationFrames;
}

async function run(): Promise<void> {
  console.log("Brief-to-video self-test (fake models)\n======================================");

  // ── coverage.repairCoverage — robust against any model output ────────────
  section("coverage.repairCoverage — robust normalization (findings 1, 2, 11, 12)");
  {
    const minF = Math.round(MIN_SHOT_SEC * FPS);
    const maxF = Math.round(MAX_SHOT_SEC * FPS);
    // finding 1: nested / non-monotonic ends no longer crash.
    const nested = repairCoverage(
      [{ startFrame: 0, endFrame: 100 }, { startFrame: 10, endFrame: 500 }, { startFrame: 20, endFrame: 200 }, { startFrame: 30, endFrame: 600 }],
      600, FPS, (i) => `n${i}`
    );
    check("nested boundaries normalize (no crash)", coverageHolds(nested, 600));
    // finding 1: overlapping ranges too.
    const overlap = repairCoverage(
      [{ startFrame: 0, endFrame: 700 }, { startFrame: 300, endFrame: 500 }, { startFrame: 400, endFrame: 900 }],
      1000, FPS, (i) => `o${i}`
    );
    check("overlapping ranges normalize", coverageHolds(overlap, 1000));
    check("normalized shots stay within [min,max]", overlap.every((s) => s.endFrame - s.startFrame >= minF && s.endFrame - s.startFrame <= maxF));
    // finding 2: zero-length timeline is covered by zero shots, no throw.
    let zeroOk = false;
    try {
      zeroOk = repairCoverage([{ startFrame: 0, endFrame: 10 }], 0, FPS, (i) => `z${i}`).length === 0;
    } catch {
      zeroOk = false;
    }
    check("zero-duration returns [] (no TypeError)", zeroOk && coverageHolds([], 0));
    // finding 11: a sliver's character/location survives the merge.
    const merged = repairCoverage(
      [{ startFrame: 0, endFrame: 150, characters: ["a"] }, { startFrame: 150, endFrame: 160, characters: ["b"], location: "kitchen", framing: "close-up" }],
      160, FPS, (i) => `m${i}`
    );
    check("merged sliver keeps its character", merged.some((s) => s.characters.includes("b")), merged.map((s) => s.characters.join("+")).join(","));
    check("merged sliver keeps its location", merged.some((s) => s.location === "kitchen"));
    // finding 12: a split shot's transcript is scoped per sub-part, not duplicated.
    const split = repairCoverage([{ startFrame: 0, endFrame: 720, audioText: "one two three four five six" }], 720, FPS, (i) => `s${i}`);
    check("split sub-shots scope their transcript", split.length >= 2 && new Set(split.map((s) => s.audioText)).size === split.length, split.map((s) => `"${s.audioText}"`).join(" | "));
  }

  // ── Entry 1: dropped audio → lip-synced video, fallback fills any hole ────
  section("provided audio → lip-synced video (findings 3, 13)");
  {
    const FAIL = "[[FAIL]]";
    const editor = editorWithAudio(DURATION_FRAMES);
    const { d, studio } = deps(editor, { failVideoMarker: FAIL, failImageMarker: FAIL, audioNative: false });
    const project = baseProject({ audioMode: "provided", audioClipId: "audio-clip", audioAssetId: "audio-asset", durationFrames: DURATION_FRAMES });
    const orch = new VideoOrchestrator(project, d);
    await orch.run();
    check("run pauses at breakdown", project.phase === "breakdown");
    check("nothing placed before approval", editor.placed.length === 0);
    project.shots[2].action = `${FAIL} a broken shot`; // dooms BOTH its keyframe and its video
    await orch.approveBreakdown();
    check("run reaches done", project.phase === "done");
    check("no holes — every shot on the timeline", project.shots.every((s) => !!s.timelineClipId));
    assertTiling("placed clips tile the whole audio", editor.placed, DURATION_FRAMES);
    const failed = project.shots.filter((s) => s.status === "failed");
    check("the doomed shot (no keyframe, no video) still filled its slot", failed.length === 1 && !!failed[0].timelineClipId);
    check("lip-sync ran for placed shots", studio.calls.some((c) => c.role === "lipsync"));
    check("no double-import of stills (fallback holds an already-imported id)", editor.placed.length === project.shots.length);
  }

  section("dailies review — a declined take retries, the pass's window trims the placement");
  {
    const editor = editorWithAudio(DURATION_FRAMES);
    const { d, studio } = deps(editor, {
      audioNative: true,
      reviewVerdicts: [
        { ok: false, note: "the subject is reading, the plan wants swimming" },
        { ok: true, fromSec: 1.5 },
      ],
    });
    const project = baseProject({ audioMode: "provided", audioClipId: "audio-clip", audioAssetId: "audio-asset", durationFrames: DURATION_FRAMES });
    const orch = new VideoOrchestrator(project, d);
    await orch.run();
    await orch.approveBreakdown();
    check("run reaches done", project.phase === "done");
    assertTiling("placed clips tile the whole audio", editor.placed, DURATION_FRAMES);
    const videoGens = studio.calls.filter((c) => c.role === "video").length;
    check("the declined take was regenerated", videoGens === project.shots.length + 1, `${videoGens} generations for ${project.shots.length} shots`);
    const reviewed = studio.calls.filter((c) => c.role === "review").length;
    check("every take was reviewed (including the retake)", reviewed === project.shots.length + 1, `${reviewed} reviews`);
    check("the retake prompt carries the reviewer's note", studio.calls.some((c) => c.role === "video" && c.detail.includes("the plan wants swimming")));
    check("the pass's window trims the placement", editor.placed.some((c) => c.srcInSec === 1.5));
    check("all shots placed clean", project.shots.every((s) => s.status === "placed"));
  }

  // ── identity policy: a moving stranger never places ──────────────────────
  // One 6s shot so verdict order is deterministic (fanOut runs shots
  // concurrently; a multi-shot project interleaves who consumes which verdict).
  const singleShot = () =>
    baseProject({ audioMode: "provided", audioClipId: "audio-clip", audioAssetId: "audio-asset", durationFrames: 6 * FPS });
  section("identity gate — a moving stranger never places");
  {
    // An identity break keeps the seed: the keyframe was gated on-model, so
    // re-animating it is the fix — the retake must ride the SAME keyframe.
    const editor = editorWithAudio(6 * FPS);
    const { d, studio } = deps(editor, {
      audioNative: true,
      reviewVerdicts: [
        { ok: false, offModel: true, note: "a different design than the sheet" },
        { ok: true },
      ],
    });
    const project = singleShot();
    const orch = new VideoOrchestrator(project, d);
    await orch.run();
    await orch.approveBreakdown();
    const takes = studio.calls.filter((c) => c.role === "video");
    check("one shot, two takes", project.shots.length === 1 && takes.length === 2, `${project.shots.length} shots, ${takes.length} takes`);
    check("the identity retake rides the same on-model seed", !!takes[0]?.keyframe && takes[0].keyframe === takes[1]?.keyframe);
    check("the passing retake placed as video", project.shots[0].status === "placed" && (project.shots[0].clip ?? "").startsWith("fake:video"));
  }
  {
    // Identity break on every attempt → the on-model keyframe still places;
    // the off-model video never does.
    const editor = editorWithAudio(6 * FPS);
    const { d, studio } = deps(editor, {
      audioNative: true,
      reviewVerdicts: Array.from({ length: VIDEO_ATTEMPTS }, () => ({ ok: false, offModel: true, note: "a different design" })),
    });
    const project = singleShot();
    const orch = new VideoOrchestrator(project, d);
    await orch.run();
    await orch.approveBreakdown();
    const shot = project.shots[0];
    const takes = studio.calls.filter((c) => c.role === "video");
    check("all attempts spent, all from the kept seed", takes.length === VIDEO_ATTEMPTS && takes.every((t) => !!t.keyframe && t.keyframe === takes[0].keyframe), `${takes.length} takes`);
    check("no off-model take placed", shot.status === "failed");
    check("the shot holds its on-model keyframe still", !!shot.startKeyframe && shot.clip === shot.startKeyframe && !!shot.timelineClipId);
    assertTiling("the still fills the slot", editor.placed, project.durationFrames);
  }
  {
    // Contrast: a non-identity flaw on the final take still places — motion
    // beats a frozen still when the character is right.
    const editor = editorWithAudio(6 * FPS);
    const { d, studio } = deps(editor, {
      audioNative: true,
      reviewVerdicts: Array.from({ length: VIDEO_ATTEMPTS }, () => ({ ok: false, note: "the action is weak" })),
    });
    const project = singleShot();
    const orch = new VideoOrchestrator(project, d);
    await orch.run();
    await orch.approveBreakdown();
    check("a weak-but-on-model final take places", project.shots[0].status === "placed" && (project.shots[0].clip ?? "").startsWith("fake:video"));
    check("all attempts were spent first", studio.calls.filter((c) => c.role === "video").length === VIDEO_ATTEMPTS);
  }

  // ── seed policy: re-mint on seed flaws, never render anchor-less ─────────
  section("seed policy — re-mint on seed flaws, restore when the mint fails");
  {
    // A seed-flaw decline mints a FRESH seed for the retake.
    const editor = editorWithAudio(6 * FPS);
    const { d, studio } = deps(editor, {
      audioNative: true,
      reviewVerdicts: [{ ok: false, note: "compose the scene upright" }, { ok: true }],
    });
    const project = singleShot();
    const orch = new VideoOrchestrator(project, d);
    await orch.run();
    await orch.approveBreakdown();
    const takes = studio.calls.filter((c) => c.role === "video");
    check("a seed-flaw retake rides a fresh seed", takes.length === 2 && !!takes[0].keyframe && !!takes[1].keyframe && takes[0].keyframe !== takes[1].keyframe);
    check("the retake placed", project.shots[0].status === "placed");
  }
  {
    // The prior seed is released only once its replacement exists: when the
    // re-mint fails (its prompt carries the critique, which is the failing
    // marker here), the retake rides the ORIGINAL keyframe — never anchor-less.
    const editor = editorWithAudio(6 * FPS);
    const { d, studio } = deps(editor, {
      audioNative: true,
      failImageMarker: "compose the scene upright",
      reviewVerdicts: [{ ok: false, note: "compose the scene upright" }, { ok: true }],
    });
    const project = singleShot();
    const orch = new VideoOrchestrator(project, d);
    await orch.run();
    await orch.approveBreakdown();
    const takes = studio.calls.filter((c) => c.role === "video");
    check("a failed re-mint restores the prior seed", takes.length === 2 && !!takes[0].keyframe && takes[0].keyframe === takes[1].keyframe);
    check("the retake placed from the restored seed", project.shots[0].status === "placed");
  }
  {
    // A refused anchor changes the identity-break policy: the stranger came
    // from WORDS (the provider blocked the seed), so re-submitting the same
    // seed re-blocks forever — the retake must mint a FRESH seed to re-roll
    // the refusal.
    const editor = editorWithAudio(6 * FPS);
    const { d, studio } = deps(editor, {
      audioNative: true,
      anchorsRefused: true,
      reviewVerdicts: [{ ok: false, offModel: true, note: "a stranger drawn from words" }, { ok: true }],
    });
    const project = singleShot();
    const orch = new VideoOrchestrator(project, d);
    await orch.run();
    await orch.approveBreakdown();
    const takes = studio.calls.filter((c) => c.role === "video");
    check("an unanchored identity break re-rolls with a fresh seed", takes.length === 2 && !!takes[0].keyframe && !!takes[1].keyframe && takes[0].keyframe !== takes[1].keyframe);
    check("the re-rolled retake placed", project.shots[0].status === "placed");
  }
  {
    // Two unanchored off-model misses mean the provider is refusing this
    // shot's seeds outright — the third re-mint must RESTAGE the seed (face
    // away from camera) instead of rolling the same composition again.
    const editor = editorWithAudio(6 * FPS);
    const { d, studio } = deps(editor, {
      audioNative: true,
      anchorsRefused: true,
      reviewVerdicts: [
        { ok: false, offModel: true, note: "a stranger" },
        { ok: false, offModel: true, note: "a stranger again" },
        { ok: true },
      ],
    });
    const project = singleShot();
    const orch = new VideoOrchestrator(project, d);
    await orch.run();
    await orch.approveBreakdown();
    const mints = studio.calls.filter((c) => c.role === "image" && c.prompt);
    check(
      "repeated refused anchors restage the seed",
      mints.some((c) => (c.prompt ?? "").includes("Restage the composition")),
      `${mints.length} mints`
    );
    check("the restaged retake placed", project.shots[0].status === "placed");
  }

  // ── the shot ladder: rung policy is data, the text rung is policy-gated ──
  section("shot ladder — the text rung opens only when the provider refuses the anchor");
  {
    const kf: AssetRef = { scope: "project", id: "kf1", name: "keyframe", kind: "image", url: "file:kf1" };
    const sheet: AssetRef = { scope: "project", id: "sheet1", name: "Mason sheet", kind: "image", url: "file:sheet1" };
    const castRefs: RefAsset[] = [
      { mediaId: "sheet1", kind: "image", purpose: "character", name: "Mason", description: "an 8-year-old boy" },
    ];
    const base = { aspect: "9:16" as const };
    const full = buildShotAttempts({
      prompt: "Mason waves.", refs: castRefs, base,
      keyframe: kf, anchors: [sheet], ridingIds: new Set(["sheet1"]),
    });
    check("three rungs, strongest first", full.length === 3 && !!full[0].opts?.refs && !!full[1].opts?.referenceImages && !full[2].opts?.refs && !full[2].opts?.referenceImages);
    check("the seed rides raw (no compose rewrite)", full[0].opts?.composeRefs === false);
    check("every rung keeps the shared base", full.every((r) => r.opts?.aspect === "9:16"));
    const gate = full[2].gate;
    check("cast text rung is gated", typeof gate === "function");
    check("the gate stays closed with no failure and on ordinary failures",
      gate?.(null) === false && gate?.("The video render is taking too long — try again.") === false && gate?.("fake video failed") === false);
    check("a person-policy refusal opens the gate",
      gate?.("The input image contains content that has been blocked by your current safety settings for person/face generation. Support codes: 17301594") === true);
    check("a format refusal opens the gate", gate?.("Unsupported image format. Expected JPEG or PNG.") === true);
    check("a filtered (empty) render opens the gate", gate?.("Omni returned no video for this request.") === true);
    const castless = buildShotAttempts({
      prompt: "an aquarium bubbles.", refs: [{ mediaId: "loc1", kind: "image", purpose: "location", name: "living room" }],
      base, keyframe: kf, anchors: [], ridingIds: new Set(),
    });
    check("a castless shot keeps an ungated text rung", castless[castless.length - 1].gate === undefined);
    const anchorless = buildShotAttempts({
      prompt: "Mason waves.", refs: castRefs, base, anchors: [], ridingIds: new Set(),
    });
    check("a cast shot with no image anchor keeps the text floor", anchorless.length === 1 && anchorless[0].gate === undefined);
  }

  // ── the ladder walk: gates and fatal stops ────────────────────────────────
  section("ladder walk — gated rungs run only on the failures they're for");
  {
    const runRungs = async (throwWith: string, gated = true) => {
      const ran: number[] = [];
      const out = await walkLadder(
        [{ prompt: "seed" }, { prompt: "text", ...(gated ? { gate: anchorRefused } : {}) }],
        async (_a, rung) => {
          ran.push(rung);
          if (rung === 0) throw new Error(throwWith);
        },
        { fatal: (e) => e === "No credits left" }
      );
      return { ran, out };
    };
    const refused = await runRungs("The input image contains content that has been blocked for person/face generation. 17301594");
    check("an anchor refusal unlocks the gated rung", refused.out.ok && refused.ran.join(",") === "0,1");
    const ordinary = await runRungs("a transient render error");
    check("an ordinary failure keeps the gated rung closed (error surfaces)", !ordinary.out.ok && ordinary.ran.join(",") === "0" && ordinary.out.error === "a transient render error");
    const broke = await runRungs("No credits left", false);
    check("a fatal failure stops the walk before ungated rungs", !broke.out.ok && broke.ran.join(",") === "0" && broke.out.error === "No credits left");
  }

  // ── Entry 2: brief only → script, voice, music, video ────────────────────
  section('brief only → "a video of me and my son", audio-native video');
  {
    const editor = emptyEditor();
    const { d, studio } = deps(editor, { audioNative: true, videoVariant: "pro" });
    const project = generatedProject();
    const orch = new VideoOrchestrator(project, d);
    await orch.run();
    check("wrote a script from the brief", !!project.script && project.script.beats.length > 0);
    check("every shot has a spoken line", project.shots.every((s) => !!s.dialogue));
    // The plan is laid out on estimated lengths; no TTS runs (spends) until the
    // user approves. voiceAssetId lands only after the gate.
    check("no voice spent before approval", studio.calls.every((c) => c.role !== "voice"));
    check("shots not yet voiced at the gate", project.shots.every((s) => !s.voiceAssetId));
    await orch.approveBreakdown();
    check("run reaches done", project.phase === "done");
    check("every shot voiced after approval", project.shots.every((s) => !!s.voiceAssetId));
    assertTiling("placed clips tile the generated spine", editor.placed, project.durationFrames);
    check("one voiceover placed per beat", editor.placedAudio.filter((a) => a.kind === "voice").length === (project.beatVoices?.length ?? -1));
    check("a single music bed spans the whole video", editor.placedAudio.filter((a) => a.kind === "music").length === 1);
    check("audio-native video carried audio inline, no lip-sync pass", studio.calls.some((c) => c.role === "video" && c.detail.includes("+audio")) && studio.calls.every((c) => c.role !== "lipsync"));
  }

  // ── finding 10: a line longer than one clip spans shots, not truncated ───
  section("long voiceover spans several shots without truncation (finding 10)");
  {
    const editor = emptyEditor();
    const { d } = deps(editor, { audioNative: true, scriptBeats: 2, voiceSeconds: 12 }); // 12s VO > 8s clip
    const project = generatedProject();
    const orch = new VideoOrchestrator(project, d);
    await orch.run();
    await orch.approveBreakdown();
    const beatFrames = Math.round(12 * FPS);
    check("each long beat became several shots", project.shots.length > (project.beatVoices?.length ?? 0));
    check("one voice clip per beat, at full length", editor.placedAudio.filter((a) => a.kind === "voice").every((a) => a.durationFrames === beatFrames));
    check("voice not truncated to the clip cap", (project.beatVoices?.every((b) => b.durationFrames === beatFrames)) ?? false);
    check("shots slice the beat's voice in order", project.shots[0].voiceFromSec === 0 && (project.shots[1].voiceFromSec ?? 0) > 0);
    assertTiling("split-beat shots still tile", editor.placed, project.durationFrames);
  }

  // ── a silent, action-only beat renders instead of failing the run ────────
  // (an empty line reaching TTS threw "Nothing to say." and killed the render)
  section("a silent beat renders without a voiceover, doesn't fail the run");
  {
    const editor = emptyEditor();
    const { d, studio } = deps(editor, { audioNative: true, scriptBeats: 3, silentBeats: [1] });
    const project = generatedProject();
    const orch = new VideoOrchestrator(project, d);
    await orch.run();
    await orch.approveBreakdown();
    check("run with a silent beat reaches done", project.phase === "done");
    check("only the two spoken beats were voiced", studio.calls.filter((c) => c.role === "voice").length === 2);
    check("the silent beat holds no voiceover asset", !project.beatVoices?.[1]?.voiceAssetId);
    check(
      "the spoken beats each hold a voiceover asset",
      !!project.beatVoices?.[0]?.voiceAssetId && !!project.beatVoices?.[2]?.voiceAssetId
    );
    check("voiceovers placed only for the spoken beats", editor.placedAudio.filter((a) => a.kind === "voice").length === 2);
    const silentShots = project.shots.filter((s) => !s.dialogue?.trim());
    check("the silent beat still rendered a shot", silentShots.length > 0);
    check("silent shots carry a clip but no voice", silentShots.every((s) => !!s.clip && !s.voiceAssetId));
    assertTiling("the silent-beat scene still tiles the spine", editor.placed, project.durationFrames);
  }

  // ── the bible is the run's spine: a failed design fails the run loudly ───
  // (a stand-in look would silently corrupt every render downstream)
  section("style-bible failure fails the run loudly (finding 8, revised)");
  {
    const editor = emptyEditor();
    const { d } = deps(editor, { audioNative: true, failStyle: true });
    const project = generatedProject();
    const orch = new VideoOrchestrator(project, d);
    await orch.run();
    let error = "";
    await orch.approveBreakdown().catch((e: unknown) => {
      error = String(e);
    });
    check("a failed style design rejects the run", error.includes("fake style design failed"));
    check("no stand-in bible is installed", project.characters.length === 0);
    check("nothing rendered under a missing bible", project.shots.every((s) => s.status !== "placed"));
  }
  section("reference-sheet failure degrades gracefully (finding 9)");
  {
    const editor = emptyEditor();
    // Fail only the character reference sheet (its prompt carries the description).
    const { d, events } = deps(editor, { audioNative: true, failImageMarker: "the person from the references" });
    const project = generatedProject();
    const orch = new VideoOrchestrator(project, d);
    await orch.run();
    await orch.approveBreakdown();
    check("a failed reference image is surfaced, not swallowed", events.some((e) => e.type === "log" && e.message.startsWith("Couldn't design")));
    check("run still completes despite the missing anchor", project.phase === "done" && tiles(editor, project.durationFrames));
  }

  // ── finding 4: regenerating a shot whose redo fails keeps its slot filled ─
  section("regenerate that fails still fills the slot (finding 4)");
  {
    const FAIL = "[[FAIL]]";
    const editor = emptyEditor();
    const { d } = deps(editor, { audioNative: true, failImageMarker: FAIL, failVideoMarker: FAIL });
    const project = generatedProject();
    const orch = new VideoOrchestrator(project, d);
    await orch.run();
    await orch.approveBreakdown();
    const before = editor.placed.length;
    await orch.regenerateShots([project.shots[0].id], (s) => {
      s.action = `${FAIL} doomed redo`;
    });
    check("redo of shot 0 still holds a still (no hole)", !!project.shots[0].timelineClipId && project.shots[0].status === "failed");
    check("track still tiles after a failed redo", tiles(editor, project.durationFrames));
    check("no extra clip left stacked", editor.placed.length === before);
  }

  // ── finding 5: resuming a 'generating' run never double-stacks ───────────
  section("resume after interruption doesn't double-stack (finding 5)");
  {
    const FAIL = "[[FAIL]]";
    const editor = emptyEditor();
    const { d } = deps(editor, { audioNative: true, failVideoMarker: FAIL });
    const project = generatedProject();
    const orch = new VideoOrchestrator(project, d);
    await orch.run();
    // Doom a shot at the gate: the voiced rescale preserves the approved shots
    // (only their frame boundaries move), so a gate-time shot edit survives to
    // the render — exactly the plan-integrity invariant the gate promises.
    project.shots[1].action = `${FAIL} broken`; // it falls back to a still
    await orch.approveBreakdown();
    const failed = project.shots.find((s) => s.status === "failed")!;
    check("interrupted shot holds a fallback still", !!failed && !!failed.timelineClipId);
    check("no hole after the fallback", editor.placed.length === project.shots.length);
    // The user fixes the shot and the run resumes from 'generating'.
    failed.action = "a fixed shot";
    project.phase = "generating";
    await orch.run();
    check("resumed shot now holds real video", failed.status === "placed");
    check("resume swapped in place — no extra clip", editor.placed.length === project.shots.length);
    assertTiling("track still tiles after resume", editor.placed, project.durationFrames);
  }

  // ── findings 6, 7: regenerate / changeStyle don't restack audio ──────────
  section("regenerate + changeStyle keep audio single (findings 6, 7)");
  {
    const editor = emptyEditor();
    const { d } = deps(editor, { audioNative: true });
    const project = generatedProject();
    const orch = new VideoOrchestrator(project, d);
    await orch.run();
    await orch.approveBreakdown();
    const voiceCount = editor.placedAudio.filter((a) => a.kind === "voice").length;
    await orch.regenerateShots([project.shots[0].id]);
    check("regenerating a shot doesn't restack its voiceover", editor.placedAudio.filter((a) => a.kind === "voice").length === voiceCount);
    await orch.changeStyle("Hand-drawn watercolor storybook.");
    check("changeStyle restores the terminal phase", project.phase === "done");
    check("changeStyle leaves exactly one music bed", editor.placedAudio.filter((a) => a.kind === "music").length === 1);
    check("changeStyle leaves one voiceover per beat", editor.placedAudio.filter((a) => a.kind === "voice").length === (project.beatVoices?.length ?? -1));
    const clips = editor.placed.length;
    await orch.run(); // resume after done is a no-op
    check("a resume after done places nothing new", editor.placed.length === clips && editor.placedAudio.filter((a) => a.kind === "music").length === 1);
    assertTiling("track still tiles after style change", editor.placed, project.durationFrames);
  }

  // ── finding 14: persistence is serialized (no interleaved writes) ────────
  section("persistence is serialized under concurrent generation (finding 14)");
  {
    let active = 0;
    let maxActive = 0;
    const editor = emptyEditor();
    const { suite } = fakeSuite({ audioNative: true });
    const project = generatedProject();
    const orch = new VideoOrchestrator(project, {
      editor,
      suite,
      emit: () => {},
      sleep: async () => {},
      persist: async () => {
        active++;
        maxActive = Math.max(maxActive, active);
        await Promise.resolve();
        active--;
      },
    });
    await orch.run();
    await orch.approveBreakdown();
    check("no two persist writes overlap", maxActive === 1, `maxActive=${maxActive}`);
  }

  // ── Model swap via the registry ──────────────────────────────────────────
  section("registry — swap the video model and both runs still tile");
  {
    const registry = fakeRegistry();
    check("registry lists swappable video models", registry.options("video").length === 2);
    for (const videoId of ["fake-fast", "fake-pro"]) {
      const suite = registry.buildSuite({ video: videoId }, `suite:${videoId}`);
      const project = generatedProject({ brief: "a short film about a lighthouse", targetSeconds: 24, suiteLabel: suite.label });
      const editor = emptyEditor();
      const orch = new VideoOrchestrator(project, { editor, suite, emit: () => {}, persist: () => {}, sleep: async () => {} });
      await orch.run();
      await orch.approveBreakdown();
      check(`${videoId}: completes and tiles`, project.phase === "done" && tiles(editor, project.durationFrames));
      const lip = project.shots.every((s) => s.lipSynced === true);
      check(`${videoId}: lip-sync ${videoId === "fake-fast" ? "post-pass used" : "inline (none)"}`, videoId === "fake-fast" ? lip : !lip);
    }
  }

  // ── fillSlot — a placed shot fills its exact slot (editor-boundary tiling) ─
  section("fillSlot — generated clips tile the timeline with no gap");
  {
    const foot = (r: { out: number; speed?: number }) => r.out / (r.speed ?? 1);
    const near = (a: number, b: number) => Math.abs(a - b) < 1e-6;
    check(
      "image takes the whole slot",
      near(foot(fillSlot("image", 0, 6, 0.25)), 6) && fillSlot("image", 0, 6, 0.25).speed === undefined
    );
    check("longer video trims to the slot", near(foot(fillSlot("video", 8, 6, 0.25)), 6));
    check("shorter video stretches to fill", near(foot(fillSlot("video", 4, 6, 0.25)), 6));
    check(
      "exact video needs no speed change",
      near(foot(fillSlot("video", 6, 6, 0.25)), 6) && fillSlot("video", 6, 6, 0.25).speed === undefined
    );
    const subFloor = fillSlot("video", 1, 6, 0.25);
    check("sub-floor video clamps speed (small gap over a crawl)", subFloor.speed === 0.25 && foot(subFloor) < 6);
  }

  console.log(`\n${failures === 0 ? "✓ ALL PASS" : `✗ ${failures} FAILED`}`);
  if (failures > 0) process.exit(1);
}

run().catch((e) => {
  console.error(e);
  process.exit(1);
});
