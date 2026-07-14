import { spawn, type ChildProcess } from "node:child_process";
import { assertLocalRuntime } from "./local-only";
import { createJobRegistry } from "./jobRegistry";
import { ensureStt } from "./transcribe";

// Live mic dictation for the AI chat composer. The browser captures the mic
// (it already holds that permission) and streams 16 kHz mono s16le PCM to the
// engine; this spawns `cut-stt --live`, forwards the PCM to its stdin, and
// exposes the evolving transcript. On-device only — nothing leaves the Mac.

export interface MicJob {
  id: string;
  status: "running" | "done" | "error" | "canceled";
  /** Latest transcript: the evolving partial while running, the final text once done. */
  text: string;
  error?: string;
  proc: ChildProcess;
  /** Resolves once the process has emitted its final text (or died). */
  finished: Promise<void>;
}

const MAX_RUNNING = 1; // on-device transcription is heavy; one dictation at a time
const { jobs, runningCount, retire } = createJobRegistry<MicJob>("__cutMicJobs");

export function getMicJob(id: string): MicJob | undefined {
  return jobs.get(id);
}

export async function startMicJob(locale: string): Promise<MicJob> {
  assertLocalRuntime();
  if (runningCount() >= MAX_RUNNING) {
    throw new Error("A dictation is already running — finish it first.");
  }
  const bin = await ensureStt();
  const id = crypto.randomUUID().slice(0, 12);
  const proc = spawn(bin, ["--live", locale], { stdio: ["pipe", "pipe", "pipe"] });

  let resolveFinished!: () => void;
  const finished = new Promise<void>((r) => (resolveFinished = r));
  const job: MicJob = { id, status: "running", text: "", proc, finished };
  jobs.set(id, job);

  // Parse the process's NDJSON stdout line by line.
  let buf = "";
  proc.stdout?.on("data", (d: Buffer) => {
    buf += d.toString();
    let nl: number;
    while ((nl = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, nl).trim();
      buf = buf.slice(nl + 1);
      if (!line) continue;
      try {
        const ev = JSON.parse(line) as { type: string; text?: string };
        if (ev.type === "partial") job.text = ev.text ?? job.text;
        else if (ev.type === "final") {
          job.text = ev.text ?? job.text;
          if (job.status === "running") job.status = "done";
        } else if (ev.type === "error") {
          job.error = ev.text || "Transcription failed.";
          if (job.status === "running") job.status = "error";
        }
      } catch {
        // Ignore a malformed line rather than tearing down a live dictation.
      }
    }
  });

  let stderr = "";
  proc.stderr?.on("data", (d: Buffer) => (stderr += d.toString()));
  proc.on("error", (e) => {
    if (job.status === "running") {
      job.status = "error";
      job.error = e.message;
    }
    resolveFinished();
    retire(job);
  });
  proc.on("close", (code) => {
    if (job.status === "running") {
      // Closed without a final line — surface whatever the process complained about.
      job.status = code === 0 ? "done" : "error";
      if (job.status === "error") job.error = stderr.trim().split("\n").slice(-2).join("\n") || `cut-stt exited ${code}`;
    }
    resolveFinished();
    retire(job);
  });

  return job;
}

/** Forward a chunk of PCM to the running process. Returns false for an unknown/ended job. */
export function feedMic(id: string, pcm: Buffer): boolean {
  const job = jobs.get(id);
  if (!job || job.status !== "running" || !job.proc.stdin?.writable) return false;
  job.proc.stdin.write(pcm);
  return true;
}

/** Close the input so the model flushes its final text, then wait for it. */
export async function stopMic(id: string): Promise<string | null> {
  const job = jobs.get(id);
  if (!job) return null;
  if (job.status === "running") job.proc.stdin?.end();
  await withTimeout(job.finished, 8000);
  return job.text;
}

/** Discard a dictation in progress. */
export function cancelMic(id: string): boolean {
  const job = jobs.get(id);
  if (!job) return false;
  if (job.status === "running") {
    job.status = "canceled";
    job.proc.kill("SIGKILL");
  }
  return true;
}

function withTimeout(p: Promise<void>, ms: number): Promise<void> {
  return new Promise((resolve) => {
    const t = setTimeout(resolve, ms);
    t.unref();
    void p.finally(() => {
      clearTimeout(t);
      resolve();
    });
  });
}
