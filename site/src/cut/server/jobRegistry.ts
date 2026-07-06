/**
 * A tiny in-memory job registry shared by the export and transcription
 * subsystems. It survives dev-server module reloads (the map hangs off
 * globalThis under `globalKey`) and keeps the map bounded: settled jobs are
 * dropped after a grace period so status polling still resolves, and the
 * terminal backlog is capped.
 */
export interface JobRegistry<J> {
  jobs: Map<string, J>;
  /** How many jobs are still running (for concurrency caps). */
  runningCount(): number;
  /** Schedule a settled job's eviction and trim the terminal backlog. */
  retire(job: J): void;
}

export function createJobRegistry<J extends { id: string; status: string }>(
  globalKey: string,
  opts: { maxJobs?: number; retireMs?: number } = {}
): JobRegistry<J> {
  const maxJobs = opts.maxJobs ?? 50;
  const retireMs = opts.retireMs ?? 10 * 60 * 1000;
  const g = globalThis as unknown as Record<string, Map<string, J> | undefined>;
  const jobs = (g[globalKey] ??= new Map<string, J>());
  const retiring = new Set<string>();

  const runningCount = () => {
    let n = 0;
    for (const j of jobs.values()) if (j.status === "running") n++;
    return n;
  };

  const retire = (job: J) => {
    if (retiring.has(job.id)) return;
    retiring.add(job.id);
    setTimeout(() => {
      jobs.delete(job.id);
      retiring.delete(job.id);
    }, retireMs).unref();
    const terminal = [...jobs.values()].filter((j) => j.status !== "running");
    for (let i = 0; i < terminal.length - maxJobs; i++) {
      jobs.delete(terminal[i].id);
      retiring.delete(terminal[i].id);
    }
  };

  return { jobs, runningCount, retire };
}
