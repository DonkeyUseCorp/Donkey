import { getJob } from "@/cut/server/jobs";
import { serveFileRange } from "@/cut/server/serveFile";

export const runtime = "nodejs";

export async function GET(
  req: Request,
  { params }: { params: Promise<{ jobId: string }> }
) {
  const { jobId } = await params;
  const job = getJob(jobId);
  if (!job || job.status !== "done") {
    return new Response("Export not ready.", { status: 404 });
  }
  return serveFileRange(job.outPath, req, {
    contentType: "video/mp4",
    downloadName: job.outName,
  });
}
