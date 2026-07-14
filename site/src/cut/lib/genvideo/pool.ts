/**
 * A bounded worker pool — the fan-out for video generation.
 *
 * Mirrors the deterministic-orchestrator `fanOut` primitive: N items run
 * through a worker at most `concurrency` in flight, one item's failure never
 * sinks the others, and each item retries with backoff before it is given up
 * on. The pool owns scheduling only; what a worker does on final failure
 * (hold a still, mark the shot) is the caller's business.
 */

export interface PoolOptions {
  /** Max workers in flight (tuned to the provider's rate limit). */
  concurrency: number;
  /** Extra attempts after the first, per item. */
  retries: number;
  /** Base backoff between attempts, ms (grows linearly with the attempt). */
  backoffMs: number;
  /** Injected sleep so tests run instantly; defaults to a real timer. */
  sleep?: (ms: number) => Promise<void>;
}

export interface PoolResult<T> {
  /** Per-item outcome in submission order: the value, or null if it gave up. */
  results: (T | null)[];
  /** Indices that exhausted their retries. */
  failures: number[];
}

const realSleep = (ms: number) =>
  new Promise<void>((r) => setTimeout(r, ms));

/**
 * Run `worker` over every item with bounded concurrency and per-item retry.
 * The returned promise never rejects — a worker that throws through all its
 * attempts lands as `null` in `results` and its index in `failures`.
 */
export async function fanOut<I, T>(
  items: I[],
  worker: (item: I, index: number) => Promise<T>,
  opts: PoolOptions
): Promise<PoolResult<T>> {
  const sleep = opts.sleep ?? realSleep;
  const concurrency = Math.max(1, Math.floor(opts.concurrency));
  const results: (T | null)[] = new Array(items.length).fill(null);
  const failures: number[] = [];
  let next = 0;

  async function runOne(index: number): Promise<void> {
    const item = items[index];
    for (let attempt = 0; attempt <= opts.retries; attempt++) {
      try {
        results[index] = await worker(item, index);
        return;
      } catch {
        if (attempt < opts.retries) await sleep(opts.backoffMs * (attempt + 1));
      }
    }
    failures.push(index);
  }

  async function drain(): Promise<void> {
    while (true) {
      const index = next++;
      if (index >= items.length) return;
      await runOne(index);
    }
  }

  const lanes = Array.from({ length: Math.min(concurrency, items.length) }, () =>
    drain()
  );
  await Promise.all(lanes);
  return { results, failures };
}
