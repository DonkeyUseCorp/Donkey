import { NextResponse } from "next/server";
import { createJob } from "@/cut/server/jobs";

export const runtime = "nodejs";
export const maxDuration = 600;

export async function POST(req: Request) {
  try {
    const form = await req.formData();
    const job = await createJob(form);
    if (job.status === "error") {
      return NextResponse.json({ error: job.error }, { status: 400 });
    }
    return NextResponse.json({ id: job.id });
  } catch (err) {
    return NextResponse.json(
      { error: err instanceof Error ? err.message : "Export failed to start." },
      { status: 500 }
    );
  }
}
