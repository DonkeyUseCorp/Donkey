/**
 * Live scene eval: drive the REAL brief-to-video pipeline in a real (headless)
 * Chrome against the dev server, and wait for every shot to settle. This is
 * the harness for judging actual output quality — real video renders, real
 * keyframes, the real director — where the fake-model self-test proves only
 * the policy mechanics.
 *
 * Auth rides the dev-only bypass header on every page request, so the run
 * needs no session cookie (dev server only; the bypass user must exist in the
 * local DB). The page exposes its stores via window.__cutDev (devHooks.ts).
 *
 *   node_modules/.bin/tsx scripts/eval-scene-live.ts --project <id> [--action retry]
 *
 * Actions:
 *   retry (default) — click-equivalent of the scene card's "Retry N shots"
 *   status          — print the run's shot states and exit
 *   watch           — open the editor (an interrupted run re-adopts its
 *                     in-flight jobs on load) and wait until every shot settles
 */

import { chromium } from "playwright";
import { readFileSync } from "node:fs";
import path from "node:path";

/** Payload for importing a local file into the page's project. */
function filePayload(p: string): { name: string; mime: string; b64: string } {
  const ext = path.extname(p).toLowerCase();
  const mime =
    ext === ".png" ? "image/png"
    : ext === ".jpg" || ext === ".jpeg" ? "image/jpeg"
    : ext === ".webp" ? "image/webp"
    : ext === ".wav" ? "audio/wav"
    : ext === ".mp3" ? "audio/mpeg"
    : ext === ".m4a" ? "audio/mp4"
    : "application/octet-stream";
  return { name: path.basename(p), mime, b64: readFileSync(p).toString("base64") };
}

const args = process.argv.slice(2);
const arg = (name: string) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
};
let PROJECT = arg("--project");
const ACTION = arg("--action") ?? "retry";
const BASE = arg("--base") ?? "http://localhost:3000";
const TIMEOUT_MIN = Number(arg("--timeout") ?? 40);
if (!PROJECT && ACTION !== "fresh") {
  console.error("--project <id> is required (except --action fresh)");
  process.exit(1);
}

const projectFile = () => path.join(process.cwd(), "projects", PROJECT!, "project.json");
type ShotRow = { id: string; status: string; attempts?: number; error?: string; clip?: string; startKeyframe?: string };
function shotsOnDisk(): { phase: string; shots: ShotRow[] } {
  const doc = JSON.parse(readFileSync(projectFile(), "utf8"));
  const g = doc.genvideo ?? {};
  return { phase: g.phase ?? "?", shots: (g.shots ?? []) as ShotRow[] };
}
function printShots(tag: string): void {
  const { phase, shots } = shotsOnDisk();
  console.log(`[${tag}] phase=${phase}`);
  for (const s of shots) {
    console.log(
      `  ${s.id}: ${s.status} att=${s.attempts ?? 0} clip=${s.clip ?? "-"} ${s.error ? `err=${s.error.slice(0, 90)}` : ""}`
    );
  }
}

async function main(): Promise<void> {
  const browser = await chromium.launch({ channel: "chrome", headless: true });
  const context = await browser.newContext({
    extraHTTPHeaders: { "x-donkey-dev-auth-bypass": "1" },
    viewport: { width: 1440, height: 900 },
  });
  const page = await context.newPage();
  page.on("console", (m) => {
    if (m.type() === "error") console.log(`[console.error] ${m.text().slice(0, 200)}`);
  });
  page.on("pageerror", (e) => console.log(`[pageerror] ${String(e).slice(0, 200)}`));

  if (ACTION === "fresh") {
    const name = arg("--name") ?? `eval ${new Date().toISOString().slice(0, 16)}`;
    const res = await fetch(`${BASE}/api/cut/projects?u=donkey-dev-auth-bypass`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name }),
    });
    if (!res.ok) throw new Error(`create project failed: ${res.status}`);
    PROJECT = ((await res.json()) as { id: string }).id;
    console.log(`[fresh] created project ${PROJECT} ("${name}")`);
  }

  console.log(`[open] ${BASE}/cut/p/${PROJECT}`);
  await page.goto(`${BASE}/cut/p/${PROJECT}`, { waitUntil: "domcontentloaded", timeout: 120_000 });
  await page.waitForFunction(
    () => {
      const dev = (window as unknown as { __cutDev?: { useEditor: { getState(): { loaded: boolean } } } }).__cutDev;
      return !!dev && dev.useEditor.getState().loaded;
    },
    undefined,
    { timeout: 120_000 }
  );
  console.log("[ready] editor loaded, dev hooks installed");

  if (ACTION === "status") {
    printShots("status");
    await browser.close();
    return;
  }

  if (ACTION === "retry") {
    const res = await page.evaluate(() => {
      const dev = (window as unknown as { __cutDev: { useGenScene: { getState(): { retryFailedShots(): { ok: boolean; message: string } } } } }).__cutDev;
      return dev.useGenScene.getState().retryFailedShots();
    });
    console.log(`[retry] ok=${res.ok} — ${res.message}`);
    if (!res.ok) {
      await browser.close();
      process.exit(2);
    }
  }

  if (ACTION === "fresh") {
    const audioPath = arg("--audio");
    const refPath = arg("--ref");
    const brief = arg("--brief") ?? "";
    const lang = arg("--lang");
    if (!audioPath || !refPath) throw new Error("--audio and --ref are required for fresh");

    // Import the audio spine and the style reference exactly as a user drop
    // would: through importFileToProject, registered on the open editor.
    const importOne = async (payload: { name: string; mime: string; b64: string }, language?: string) => {
      const assetId = await page.evaluate(
        async ({ file, language, projectId }) => {
          const dev = (window as unknown as {
            __cutDev: {
              importFileToProject(id: string, f: File): Promise<{ id: string } | null>;
              enrichAsset(a: unknown): Promise<void>;
              useEditor: { getState(): { addAsset(a: unknown): void; updateAsset(id: string, patch: unknown): void } };
            };
          }).__cutDev;
          const bytes = Uint8Array.from(atob(file.b64), (c) => c.charCodeAt(0));
          const f = new File([bytes], file.name, { type: file.mime });
          const asset = await dev.importFileToProject(projectId, f);
          if (!asset) return null;
          dev.useEditor.getState().addAsset(asset);
          if (language) dev.useEditor.getState().updateAsset(asset.id, { language });
          await dev.enrichAsset(asset);
          return asset.id;
        },
        { file: payload, language: language ?? null, projectId: PROJECT! }
      );
      if (!assetId) throw new Error(`import failed for ${payload.name}`);
      return assetId as string;
    };
    const audioId = await importOne(filePayload(audioPath), lang ?? undefined);
    const refId = await importOne(filePayload(refPath));
    console.log(`[fresh] imported audio=${audioId} ref=${refId}`);

    const started = await page.evaluate(
      async ({ projectId, brief, audioId, refId }) => {
        const dev = (window as unknown as {
          __cutDev: {
            useEditor: { getState(): { setAspect(a: string): void } };
            useGenScene: {
              getState(): {
                start(
                  id: string,
                  params: Record<string, unknown>
                ): Promise<{ started: boolean; shotCount?: number; message: string }>;
              };
            };
          };
        }).__cutDev;
        dev.useEditor.getState().setAspect("9:16");
        return dev.useGenScene.getState().start(projectId, {
          ...(brief ? { brief } : {}),
          fromAudioAssetId: audioId,
          aspect: "9:16",
          referenceAssetIds: [refId],
        });
      },
      { projectId: PROJECT!, brief, audioId, refId }
    );
    console.log(`[fresh] planned: started=${started.started} shots=${started.shotCount ?? "?"} — ${started.message}`);
    if (!started.started) {
      await browser.close();
      process.exit(2);
    }
    const approved = await page.evaluate(() => {
      const dev = (window as unknown as { __cutDev: { useGenScene: { getState(): { approve(): { ok: boolean; message: string } } } } }).__cutDev;
      return dev.useGenScene.getState().approve();
    });
    console.log(`[fresh] approve: ok=${approved.ok} — ${approved.message}`);
    if (!approved.ok) {
      await browser.close();
      process.exit(2);
    }
  }

  // Poll until every shot settles and no render job is still in flight — the
  // pipeline runs in this page, so the page must stay open throughout.
  const waitSettled = async (deadline: number): Promise<void> => {
    let lastLine = "";
    for (;;) {
      if (Date.now() > deadline) {
        printShots("timeout");
        await browser.close();
        process.exit(3);
      }
      await new Promise((r) => setTimeout(r, 10_000));
      const live = await page.evaluate(() => {
        const dev = (window as unknown as {
          __cutDev: {
            useGenerate: { getState(): { jobs: { status: string }[] } };
            useGenScene: { getState(): { run: { status: string } | null } };
          };
        }).__cutDev;
        const jobs = dev.useGenerate.getState().jobs.filter((j) => j.status === "running").length;
        const run = dev.useGenScene.getState().run;
        return { jobs, runStatus: run?.status ?? "none" };
      });
      const { shots } = shotsOnDisk();
      const settled = shots.every((s) => s.status === "placed" || s.status === "failed");
      const line = `run=${live.runStatus} jobs=${live.jobs} shots=[${shots.map((s) => s.status).join(",")}]`;
      if (line !== lastLine) {
        console.log(`[poll] ${line}`);
        lastLine = line;
      }
      if (live.runStatus !== "generating" && live.jobs === 0 && settled) return;
    }
  };
  const deadline = Date.now() + TIMEOUT_MIN * 60_000;

  if (ACTION === "redo") {
    // Sequential per-shot redos (1-based numbers) — each waits for the run to
    // settle before the next starts, since only a done run accepts a redo.
    const ns = String(arg("--shots") ?? "")
      .split(",")
      .map((v) => Number(v.trim()))
      .filter((v) => Number.isFinite(v) && v > 0);
    if (ns.length === 0) throw new Error("--shots 1,2,… required for redo");
    const note = arg("--note");
    for (const n of ns) {
      const res = await page.evaluate(({ num, note }) => {
        const dev = (window as unknown as { __cutDev: { useGenScene: { getState(): { regenerateShot(n: number, note?: string): { ok: boolean; message: string } } } } }).__cutDev;
        return dev.useGenScene.getState().regenerateShot(num, note || undefined);
      }, { num: n, note: note ?? null });
      console.log(`[redo shot ${n}] ok=${res.ok} — ${res.message}`);
      if (!res.ok) {
        await browser.close();
        process.exit(2);
      }
      await waitSettled(deadline);
      printShots(`after shot ${n}`);
    }
    await browser.close();
    return;
  }

  await waitSettled(deadline);
  printShots("done");
  await browser.close();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
