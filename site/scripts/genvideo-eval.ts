/**
 * Model-comparison eval: run the same brief through several model suites and
 * compare them side by side. Swapping the video (or any) model is swapping one
 * id in a suite selection; the harness runs each suite through the real
 * orchestrator and reports coverage, shots, fallbacks, lip-sync, and wall-clock.
 *
 * Today it runs against the fake registry, so it proves the comparison
 * mechanics without spending credits. To compare real models, register real
 * adapters in the registry and pass a real (recording) editor + real reference
 * ids — the recording editor already captures every produced clip, which is
 * what a side-by-side gallery renders.
 *
 *   node_modules/.bin/bun run scripts/genvideo-eval.ts "a video of me and my son, cinematic"
 */

import { assertCoverage } from "../src/cut/lib/genvideo/coverage";
import { FakeEditor } from "../src/cut/lib/genvideo/editor";
import { fakeRegistry } from "../src/cut/lib/genvideo/registry";
import { VideoOrchestrator } from "../src/cut/lib/genvideo/orchestrator";
import type { RoleName } from "../src/cut/lib/genvideo/capabilities";
import type { VideoProject } from "../src/cut/lib/genvideo/types";

const FPS = 30;

/** The suites to compare. Each differs from the others by one model id. Add a
 * real entry the moment a real adapter is registered. */
const SUITES: { name: string; selection: Partial<Record<RoleName, string>> }[] = [
  { name: "fast-video", selection: { video: "fake-fast" } },
  { name: "pro-video", selection: { video: "fake-pro" } },
];

interface SuiteMetrics {
  suite: string;
  videoModel: string;
  coverageOk: boolean;
  shots: number;
  durationSec: number;
  placed: number;
  fallbacks: number;
  lipSyncShots: number;
  producedClips: string[];
  wallMs: number;
}

async function runSuite(name: string, selection: Partial<Record<RoleName, string>>, brief: string): Promise<SuiteMetrics> {
  const registry = fakeRegistry();
  const suite = registry.buildSuite(selection, name);
  const project: VideoProject = {
    id: `eval:${name}`,
    brief,
    references: [{ mediaId: "ref:user", kind: "image", purpose: "character", name: "the user" }],
    audioMode: "generated",
    fps: FPS,
    durationFrames: 0,
    transcript: [],
    style: "",
    suiteLabel: suite.label,
    characters: [],
    locations: [],
    shots: [],
    phase: "brief",
    breakdownApproved: true, // evals don't pause for a human
    createdAt: 0,
    updatedAt: 0,
    targetSeconds: 30,
  };
  const editor = new FakeEditor({ fps: FPS, durationFrames: 0, aspect: "9:16" }, []);
  const orch = new VideoOrchestrator(project, { editor, suite, emit: () => {}, persist: () => {}, sleep: async () => {} });

  const t0 = performance.now();
  await orch.run();
  const wallMs = performance.now() - t0;

  let coverageOk = true;
  try {
    assertCoverage(project.shots, project.durationFrames);
  } catch {
    coverageOk = false;
  }
  return {
    suite: name,
    videoModel: selection.video ?? "(default)",
    coverageOk,
    shots: project.shots.length,
    durationSec: Math.round((project.durationFrames / FPS) * 10) / 10,
    placed: project.shots.filter((s) => s.status === "placed").length,
    fallbacks: project.shots.filter((s) => s.status === "failed").length,
    lipSyncShots: project.shots.filter((s) => s.lipSynced).length,
    producedClips: project.shots.map((s) => s.clip ?? "(none)"),
    wallMs: Math.round(wallMs * 10) / 10,
  };
}

function table(rows: SuiteMetrics[]): string {
  const head = ["suite", "video model", "coverage", "shots", "dur(s)", "placed", "fallback", "lip-sync", "wall(ms)"];
  const body = rows.map((r) => [
    r.suite,
    r.videoModel,
    r.coverageOk ? "ok" : "BROKEN",
    String(r.shots),
    String(r.durationSec),
    String(r.placed),
    String(r.fallbacks),
    String(r.lipSyncShots),
    String(r.wallMs),
  ]);
  const widths = head.map((h, i) => Math.max(h.length, ...body.map((row) => row[i].length)));
  const fmt = (cols: string[]) => cols.map((c, i) => c.padEnd(widths[i])).join("  ");
  return [fmt(head), fmt(widths.map((w) => "-".repeat(w))), ...body.map(fmt)].join("\n");
}

async function main(): Promise<void> {
  const brief = process.argv[2] ?? "a video of me and my son at the beach, cinematic";
  console.log(`Model-comparison eval\nbrief: "${brief}"\n`);
  const rows: SuiteMetrics[] = [];
  for (const s of SUITES) rows.push(await runSuite(s.name, s.selection, brief));

  console.log(table(rows));

  const broken = rows.filter((r) => !r.coverageOk);
  if (broken.length) {
    console.log(`\n✗ ${broken.length} suite(s) failed the coverage invariant: ${broken.map((r) => r.suite).join(", ")}`);
    process.exit(1);
  }
  // With fakes every suite is instant and correct; the ranking mechanic is what
  // matters — fewest fallbacks, then fastest. Real runs make this meaningful.
  const best = [...rows].sort((a, b) => a.fallbacks - b.fallbacks || a.wallMs - b.wallMs)[0];
  console.log(`\n✓ all suites covered the audio. Leading suite by fallbacks then speed: ${best.suite}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
