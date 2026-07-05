import { NextResponse } from "next/server";

export const runtime = "nodejs";

import {
  createTranscribeJob,
  getTranscribeJob,
  type TranscribeSpec,
} from "@/cut/server/transcribe";

/** Start a background transcription of the current cut. */
export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  try {
    const body = (await req.json()) as Omit<TranscribeSpec, "projectId">;
    if (!Array.isArray(body.clips) || typeof body.duration !== "number") {
      return NextResponse.json({ error: "Bad transcribe spec." }, { status: 400 });
    }
    const job = await createTranscribeJob({ ...body, projectId: id });
    return NextResponse.json({ id: job.id });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return NextResponse.json({ error: message }, { status: 500 });
  }
}

/** Poll a transcription job: ?job=<id> */
export async function GET(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const jobId = new URL(req.url).searchParams.get("job");
  const job = jobId ? getTranscribeJob(jobId) : undefined;
  if (!job || job.projectId !== id) {
    return NextResponse.json({ error: "Unknown transcription job." }, { status: 404 });
  }
  return NextResponse.json({
    status: job.status,
    stage: job.stage,
    error: job.error,
    cues: job.status === "done" ? job.cues : undefined,
  });
}
