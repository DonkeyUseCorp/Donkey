/**
 * Brief-to-video self-test — proves the timeline math and the coverage
 * invariant with fake models before any real generation is wired, and locks in
 * a regression check for every bug the xhigh code review surfaced.
 *
 *   node_modules/.bin/bun run scripts/genvideo-selftest.ts
 */

import { assertCoverage, MAX_SHOT_SEC, MIN_SHOT_SEC, repairCoverage } from "../src/cut/lib/genvideo/coverage";
import { FakeEditor, type PlacedClip } from "../src/cut/lib/genvideo/editor";
import { fakeSuite, type FakeStudioOptions } from "../src/cut/lib/genvideo/fakes";
import { fakeRegistry } from "../src/cut/lib/genvideo/registry";
import { VideoOrchestrator, type OrchestratorDeps } from "../src/cut/lib/genvideo/orchestrator";
import type { VideoEvent, VideoProject } from "../src/cut/lib/genvideo/types";

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

  // ── Entry 2: brief only → script, voice, music, video ────────────────────
  section('brief only → "a video of me and my son", audio-native video');
  {
    const editor = emptyEditor();
    const { d, studio } = deps(editor, { audioNative: true, videoVariant: "pro" });
    const project = generatedProject();
    const orch = new VideoOrchestrator(project, d);
    await orch.run();
    check("wrote a script from the brief", !!project.script && project.script.beats.length > 0);
    check("every shot has a spoken line", project.shots.every((s) => !!s.dialogue && !!s.voiceAssetId));
    await orch.approveBreakdown();
    check("run reaches done", project.phase === "done");
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

  // ── findings 8, 9: style failures degrade instead of dropping anchors ────
  section("style-bible failure degrades gracefully (findings 8, 9)");
  {
    const editor = emptyEditor();
    const { d } = deps(editor, { audioNative: true, failStyle: true });
    const project = generatedProject();
    const orch = new VideoOrchestrator(project, d);
    await orch.run();
    await orch.approveBreakdown();
    check("style failure still yields a character bible", project.characters.length > 0);
    check("reference image minted from the default bible", project.characters.every((c) => !!c.mediaId));
    check("run still completes and tiles", project.phase === "done" && tiles(editor, project.durationFrames));
  }
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
    project.shots[1].action = `${FAIL} broken`; // this shot will fall back to a still
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

  console.log(`\n${failures === 0 ? "✓ ALL PASS" : `✗ ${failures} FAILED`}`);
  if (failures > 0) process.exit(1);
}

run().catch((e) => {
  console.error(e);
  process.exit(1);
});
