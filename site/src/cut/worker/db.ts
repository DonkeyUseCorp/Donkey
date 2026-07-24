import { prisma } from "@/lib/prisma";

export { prisma };

/** The columns a claimed CutRenderJob row hands the job runners. */
export interface ClaimedJob {
  id: string;
  userId: string;
  projectId: string | null;
  kind: string;
  spec: unknown;
  outName: string | null;
}

/**
 * Record a finished R2 object and keep the user's storage total in step. The
 * upsert makes re-registering the same key (a preview re-render, a retried
 * job) charge only the size delta instead of double-counting.
 */
export async function registerObject(opts: {
  userId: string;
  projectId: string;
  r2Key: string;
  fileName: string;
  mime: string;
  bytes: number;
  kind: string;
}): Promise<void> {
  const prior = await prisma.cutMediaObject.findUnique({
    where: { r2Key: opts.r2Key },
    select: { bytes: true, uploadState: true },
  });
  const priorBytes = prior?.uploadState === "complete" ? prior.bytes : BigInt(0);
  const delta = BigInt(opts.bytes) - priorBytes;
  await prisma.$transaction([
    prisma.cutMediaObject.upsert({
      where: { r2Key: opts.r2Key },
      create: {
        userId: opts.userId,
        projectId: opts.projectId,
        r2Key: opts.r2Key,
        fileName: opts.fileName,
        mime: opts.mime,
        bytes: BigInt(opts.bytes),
        kind: opts.kind,
        uploadState: "complete",
      },
      update: { bytes: BigInt(opts.bytes), uploadState: "complete" },
    }),
    prisma.cutStorageUsage.upsert({
      where: { userId: opts.userId },
      create: { userId: opts.userId, bytes: delta },
      update: { bytes: { increment: delta } },
    }),
  ]);
}
