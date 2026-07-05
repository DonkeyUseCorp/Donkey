import type { ProjectDoc } from "@/cut/lib/types";
import { makeFreezeFrame } from "../frames";
import {
  createProject,
  deleteProject,
  exportPath,
  listExports,
  listProjects,
  mediaPath,
  readProject,
  saveMedia,
  writeProject,
} from "../projects";
import { serveFileRange } from "../serveFile";
import { createTranscribeJob, getTranscribeJob, type TranscribeSpec } from "../transcribe";

const err = (message: string, status: number) => Response.json({ error: message }, { status });
const caught = (e: unknown, fallback: string, status = 500) =>
  err(e instanceof Error ? e.message : fallback, status);

/** Project CRUD, media, exports, transcription, freeze-frames. */
export const projectsApi = {
  async list() {
    return Response.json(await listProjects());
  },

  async create(req: Request) {
    try {
      const { name } = (await req.json()) as { name?: string };
      return Response.json(await createProject(name ?? "Untitled"));
    } catch (e) {
      return caught(e, "Could not create project.");
    }
  },

  async get(_req: Request, { id }: { id: string }) {
    const doc = await readProject(id).catch(() => null);
    if (!doc) return err("Project not found.", 404);
    return Response.json(doc);
  },

  async put(req: Request, { id }: { id: string }) {
    try {
      const existing = await readProject(id);
      if (!existing) return err("Project not found.", 404);
      const body = (await req.json()) as Partial<ProjectDoc>;
      const doc: ProjectDoc = {
        ...existing,
        name: typeof body.name === "string" && body.name.trim() ? body.name.trim() : existing.name,
        assets: Array.isArray(body.assets) ? body.assets : existing.assets,
        clips: Array.isArray(body.clips) ? body.clips : existing.clips,
        audioClips: Array.isArray(body.audioClips) ? body.audioClips : existing.audioClips,
        overlays: Array.isArray(body.overlays) ? body.overlays : existing.overlays,
        subtitles:
          body.subtitles && typeof body.subtitles === "object"
            ? body.subtitles
            : existing.subtitles,
        // Per-project view metadata (timeline zoom, …) — not part of the cut.
        ui:
          body.ui && typeof body.ui === "object" ? { ...existing.ui, ...body.ui } : existing.ui,
        publish:
          body.publish && typeof body.publish === "object"
            ? { ...existing.publish, ...body.publish }
            : existing.publish,
      };
      await writeProject(id, doc);
      return Response.json({ ok: true, updatedAt: doc.updatedAt });
    } catch (e) {
      return caught(e, "Could not save project.");
    }
  },

  async remove(_req: Request, { id }: { id: string }) {
    try {
      await deleteProject(id);
      return Response.json({ ok: true });
    } catch (e) {
      return caught(e, "Could not delete project.");
    }
  },

  async uploadMedia(req: Request, { id }: { id: string }) {
    try {
      if (!(await readProject(id))) return err("Project not found.", 404);
      const form = await req.formData();
      const file = form.get("file");
      if (!(file instanceof File)) return err("No file in upload.", 400);
      const fileName = await saveMedia(id, file);
      return Response.json({ fileName });
    } catch (e) {
      return caught(e, "Upload failed.");
    }
  },

  /** Raw media file with Range support so <video>/<audio> can seek. */
  async serveMedia(req: Request, { id, file }: { id: string; file: string }) {
    let p: string;
    try {
      p = mediaPath(id, decodeURIComponent(file));
    } catch {
      return new Response("Bad request.", { status: 400 });
    }
    return serveFileRange(p, req);
  },

  /** Rendered exports for a project, newest first. */
  async listExports(_req: Request, { id }: { id: string }) {
    try {
      return Response.json(await listExports(id));
    } catch {
      return err("Invalid project.", 400);
    }
  },

  /** A rendered export with Range support so the preview player can seek. */
  async serveExport(req: Request, { id, file }: { id: string; file: string }) {
    let p: string;
    try {
      p = exportPath(id, decodeURIComponent(file));
    } catch {
      return new Response("Bad request.", { status: 400 });
    }
    return serveFileRange(p, req, { contentType: "video/mp4" });
  },

  /** Start a background transcription of the current cut. */
  async transcribeStart(req: Request, { id }: { id: string }) {
    try {
      const body = (await req.json()) as Omit<TranscribeSpec, "projectId">;
      if (!Array.isArray(body.clips) || typeof body.duration !== "number") {
        return err("Bad transcribe spec.", 400);
      }
      const job = await createTranscribeJob({ ...body, projectId: id });
      return Response.json({ id: job.id });
    } catch (e) {
      return caught(e, String(e));
    }
  },

  /** Poll a transcription job: ?job=<id> */
  async transcribePoll(req: Request, { id }: { id: string }) {
    const jobId = new URL(req.url).searchParams.get("job");
    const job = jobId ? getTranscribeJob(jobId) : undefined;
    if (!job || job.projectId !== id) return err("Unknown transcription job.", 404);
    return Response.json({
      status: job.status,
      stage: job.stage,
      error: job.error,
      cues: job.status === "done" ? job.cues : undefined,
    });
  },

  /** Render a freeze-frame still clip from a media file's frame. */
  async freeze(req: Request, { id }: { id: string }) {
    try {
      if (!(await readProject(id))) return err("Project not found.", 404);
      const body = (await req.json()) as {
        file?: string;
        srcTime?: number;
        duration?: number;
        frame?: { w?: number; h?: number };
        framing?: { fit?: "fit" | "fill"; panX?: number; panY?: number };
      };
      if (!body.file || typeof body.srcTime !== "number") {
        return err("file and srcTime are required.", 400);
      }
      const frame =
        typeof body.frame?.w === "number" && typeof body.frame?.h === "number"
          ? { w: Math.round(body.frame.w), h: Math.round(body.frame.h) }
          : undefined;
      const framing = frame
        ? {
            fit: body.framing?.fit === "fill" ? ("fill" as const) : ("fit" as const),
            panX: typeof body.framing?.panX === "number" ? body.framing.panX : 0,
            panY: typeof body.framing?.panY === "number" ? body.framing.panY : 0,
          }
        : undefined;
      const made = await makeFreezeFrame(id, body.file, body.srcTime, body.duration ?? 1, frame, framing);
      return Response.json({
        id: crypto.randomUUID().slice(0, 8),
        fileName: made.fileName,
        name: made.fileName,
        type: "video",
        duration: made.duration,
        width: made.width,
        height: made.height,
      });
    } catch (e) {
      return caught(e, String(e));
    }
  },
};
