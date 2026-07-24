// Storage garbage collection: presigned-but-never-completed media objects and
// long-terminal render jobs. Runs from the Vercel daily cron (vercel.json) or
// a superuser hitting GET /api/cut-cloud/gc.
import { prisma } from "@/lib/prisma";
import { del } from "./r2";

const PENDING_MAX_AGE_MS = 24 * 60 * 60 * 1000;
const JOB_MAX_AGE_MS = 30 * 24 * 60 * 60 * 1000;
const TERMINAL_STATES = ["done", "error", "canceled"];

export async function runGc(): Promise<Response> {
  const pending = await prisma.cutMediaObject.findMany({
    where: {
      uploadState: "pending",
      createdAt: { lt: new Date(Date.now() - PENDING_MAX_AGE_MS) },
    },
    select: { id: true, r2Key: true },
  });
  // Pending rows never counted toward usage, so no usage adjustment here.
  await del(pending.map((o) => o.r2Key));
  if (pending.length > 0) {
    await prisma.cutMediaObject.deleteMany({
      where: { id: { in: pending.map((o) => o.id) } },
    });
  }
  // Old terminal jobs go together with their overlay PNGs — the worker deletes
  // overlays when it settles a job, but a job canceled while still queued was
  // never claimed, so its overlays only die here.
  const oldJobs = await prisma.cutRenderJob.findMany({
    where: {
      state: { in: TERMINAL_STATES },
      createdAt: { lt: new Date(Date.now() - JOB_MAX_AGE_MS) },
    },
    select: { id: true, userId: true, spec: true },
  });
  const overlayKeys = oldJobs.flatMap((j) => {
    const overlays = (j.spec as { overlays?: { key?: unknown }[] } | null)?.overlays ?? [];
    const prefix = `cut/${j.userId}/overlays/`;
    return overlays
      .map((o) => o?.key)
      .filter((k): k is string => typeof k === "string" && k.startsWith(prefix));
  });
  await del(overlayKeys);
  const jobs =
    oldJobs.length > 0
      ? await prisma.cutRenderJob.deleteMany({ where: { id: { in: oldJobs.map((j) => j.id) } } })
      : { count: 0 };
  return Response.json({ pendingObjects: pending.length, renderJobs: jobs.count });
}
