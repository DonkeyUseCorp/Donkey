import {
  addFromProject,
  addUpload,
  libMediaPath,
  listLibrary,
  removeAsset,
  useInProject,
} from "../library";
import { serveFileRange } from "../serveFile";

const err = (message: string, status: number) => Response.json({ error: message }, { status });
const caught = (e: unknown, fallback: string) =>
  err(e instanceof Error ? e.message : fallback, 500);

/** The shared library: reusable media outside any project. */
export const libraryApi = {
  async list() {
    return Response.json(await listLibrary());
  },

  async upload(req: Request) {
    try {
      const form = await req.formData();
      const file = form.get("file");
      if (!(file instanceof File)) return err("No file in upload.", 400);
      return Response.json(await addUpload(file));
    } catch (e) {
      return caught(e, "Upload failed.");
    }
  },

  async remove(_req: Request, { id }: { id: string }) {
    try {
      await removeAsset(id);
      return Response.json({ ok: true });
    } catch (e) {
      return caught(e, "Could not delete.");
    }
  },

  /** Copy a library asset into a project's media folder. */
  async use(req: Request) {
    try {
      const { assetId, projectId } = (await req.json()) as {
        assetId: string;
        projectId: string;
      };
      const fileName = await useInProject(assetId, projectId);
      return Response.json({ fileName });
    } catch (e) {
      return caught(e, "Could not add from library.");
    }
  },

  /** Copy a project media file into the shared library. */
  async save(req: Request) {
    try {
      const { projectId, fileName, name } = (await req.json()) as {
        projectId: string;
        fileName: string;
        name?: string;
      };
      return Response.json(await addFromProject(projectId, fileName, name ?? fileName));
    } catch (e) {
      return caught(e, "Could not save to library.");
    }
  },

  /** Raw library media file with Range support. */
  async serveMedia(req: Request, { file }: { file: string }) {
    let p: string;
    try {
      p = libMediaPath(decodeURIComponent(file));
    } catch {
      return new Response("Bad request.", { status: 400 });
    }
    return serveFileRange(p, req);
  },
};
