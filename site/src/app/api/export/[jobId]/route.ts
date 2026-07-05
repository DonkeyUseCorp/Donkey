import { NextResponse } from "next/server";
import { cancelJob, getJob } from "@/cut/server/jobs";

export const runtime = "nodejs";

export async function GET(
  _req: Request,
  { params }: { params: Promise<{ jobId: string }> }
) {
  const { jobId } = await params;
  const job = getJob(jobId);
  if (!job) return NextResponse.json({ error: "Unknown export." }, { status: 404 });
  return NextResponse.json({
    status: job.status,
    progress: job.progress,
    error: job.error,
    outName: job.outName,
  });
}

export async function DELETE(
  _req: Request,
  { params }: { params: Promise<{ jobId: string }> }
) {
  const { jobId } = await params;
  cancelJob(jobId);
  return NextResponse.json({ ok: true });
}
