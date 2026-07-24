// Storage garbage collection: presigned-but-never-completed media objects,
// project media no doc references, and long-terminal render jobs. Runs from
// the Vercel daily cron (vercel.json) or a superuser hitting
// GET /api/cut-cloud/gc.
import { prisma } from "@/lib/prisma";
import { del } from "./r2";
import { addUsage } from "./usage";

const PENDING_MAX_AGE_MS = 24 * 60 * 60 * 1000;
const ORPHAN_MAX_AGE_MS = 24 * 60 * 60 * 1000;
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
  // Unreferenced project media: bytes a worker or client landed in a project
  // whose doc never adopted them — an abandoned import, a tab closed before
  // the save. The doc is the sole owner of project media, adoption happens
  // within seconds of landing, and the one delayed delivery path (the cloud
  // import poll) caps at ten minutes — so after a day of grace, unreferenced
  // means garbage. Docs of deleted projects are gone too, which orphans (and
  // sweeps) any rows their deletion missed.
  const mediaCandidates = await prisma.cutMediaObject.findMany({
    where: {
      kind: "media",
      uploadState: "complete",
      projectId: { not: null },
      updatedAt: { lt: new Date(Date.now() - ORPHAN_MAX_AGE_MS) },
    },
    select: { id: true, userId: true, projectId: true, fileName: true, r2Key: true, bytes: true },
  });
  const docProjects = await prisma.cutProject.findMany({
    where: { id: { in: [...new Set(mediaCandidates.map((c) => c.projectId!))] } },
    select: { id: true, doc: true },
  });
  const referenced = new Map(
    docProjects.map((p) => {
      const assets = (p.doc as { assets?: { fileName?: string }[] } | null)?.assets ?? [];
      return [p.id, new Set(assets.map((a) => a.fileName))];
    })
  );
  const orphans = mediaCandidates.filter((c) => !referenced.get(c.projectId!)?.has(c.fileName));
  const byUser = new Map<string, typeof orphans>();
  for (const o of orphans) {
    const list = byUser.get(o.userId) ?? [];
    list.push(o);
    byUser.set(o.userId, list);
  }
  for (const [userId, rows] of byUser) {
    await prisma.$transaction(async (tx) => {
      await tx.cutMediaObject.deleteMany({ where: { id: { in: rows.map((r) => r.id) } } });
      await addUsage(tx, userId, -rows.reduce((sum, r) => sum + Number(r.bytes), 0));
    });
    await del(rows.map((r) => r.r2Key));
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
  return Response.json({
    pendingObjects: pending.length,
    orphanedMedia: orphans.length,
    renderJobs: jobs.count,
  });
}
