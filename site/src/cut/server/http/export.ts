import { cancelJob, createJob, getJob, listJobsForProject } from "../jobs";
import { serveFileRange } from "../serveFile";

/** Export rendering: start a job, poll it, cancel it, download the result. */
export const exportApi = {
  /** Export jobs (running or recently settled) for a project, so a reopened or
   * reloaded editor can reconnect to a render still in flight. */
  activeForProject(_req: Request, { id }: { id: string }) {
    return Response.json(listJobsForProject(id));
  },

  async create(req: Request) {
    try {
      const form = await req.formData();
      const job = await createJob(form);
      if (job.status === "error") {
        return Response.json({ error: job.error }, { status: 400 });
      }
      return Response.json({ id: job.id });
    } catch (e) {
      return Response.json(
        { error: e instanceof Error ? e.message : "Export failed to start." },
        { status: 500 }
      );
    }
  },

  async status(_req: Request, { jobId }: { jobId: string }) {
    const job = getJob(jobId);
    if (!job) return Response.json({ error: "Unknown export." }, { status: 404 });
    return Response.json({
      status: job.status,
      progress: job.progress,
      error: job.error,
      outName: job.outName,
    });
  },

  async cancel(_req: Request, { jobId }: { jobId: string }) {
    cancelJob(jobId);
    return Response.json({ ok: true });
  },

  async file(req: Request, { jobId }: { jobId: string }) {
    const job = getJob(jobId);
    if (!job || job.status !== "done") {
      return new Response("Export not ready.", { status: 404 });
    }
    return serveFileRange(job.outPath, req, {
      contentType: "video/mp4",
      downloadName: job.outName,
    });
  },
};
