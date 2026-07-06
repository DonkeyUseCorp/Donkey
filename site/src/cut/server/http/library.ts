import {
  addFromProject,
  addUpload,
  createFolder,
  deleteFolder,
  ensureLibraryThumb,
  libMediaPath,
  listFolders,
  listLibrary,
  moveAsset,
  removeAsset,
  renameFolder,
  useInProject,
} from "../library";
import { serveFileRange } from "../serveFile";
import { importFromUrl } from "../urlImport";

const err = (message: string, status: number) => Response.json({ error: message }, { status });
const caught = (e: unknown, fallback: string) =>
  err(e instanceof Error ? e.message : fallback, 500);

/** The shared library: reusable media outside any project. */
export const libraryApi = {
  async list() {
    const [assets, folders] = await Promise.all([listLibrary(), listFolders()]);
    return Response.json({ assets, folders });
  },

  /** A sharp, cached still for a library video. */
  async serveThumb(req: Request, { id }: { id: string }) {
    try {
      const p = await ensureLibraryThumb(decodeURIComponent(id));
      if (!p) return new Response("No thumbnail.", { status: 404 });
      return serveFileRange(p, req);
    } catch {
      return new Response("No thumbnail.", { status: 404 });
    }
  },

  /** Download a media URL straight into the library. */
  async importUrl(req: Request) {
    try {
      const { url } = (await req.json()) as { url?: string };
      if (!url) return err("No URL provided.", 400);
      return Response.json(await importFromUrl(url));
    } catch (e) {
      return caught(e, "Could not import that URL.");
    }
  },

  async createFolder(req: Request) {
    try {
      const { name } = (await req.json()) as { name?: string };
      return Response.json(await createFolder(name ?? ""));
    } catch (e) {
      return caught(e, "Could not create folder.");
    }
  },

  async renameFolder(req: Request, { id }: { id: string }) {
    try {
      const { name } = (await req.json()) as { name?: string };
      return Response.json(await renameFolder(id, name ?? ""));
    } catch (e) {
      return caught(e, "Could not rename folder.");
    }
  },

  async deleteFolder(_req: Request, { id }: { id: string }) {
    try {
      await deleteFolder(id);
      return Response.json({ ok: true });
    } catch (e) {
      return caught(e, "Could not delete folder.");
    }
  },

  /** Move an asset into a folder (or `null` to ungroup). */
  async move(req: Request) {
    try {
      const { assetId, folderId } = (await req.json()) as {
        assetId: string;
        folderId: string | null;
      };
      await moveAsset(assetId, folderId ?? null);
      return Response.json({ ok: true });
    } catch (e) {
      return caught(e, "Could not move asset.");
    }
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
