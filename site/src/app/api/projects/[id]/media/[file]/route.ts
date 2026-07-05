import { mediaPath } from "@/cut/server/projects";
import { serveFileRange } from "@/cut/server/serveFile";

export const runtime = "nodejs";

/** Serve a raw media file from the project folder, with Range support so
 * <video>/<audio> elements can seek efficiently. */
export async function GET(
  req: Request,
  { params }: { params: Promise<{ id: string; file: string }> }
) {
  const { id, file } = await params;
  let p: string;
  try {
    p = mediaPath(id, decodeURIComponent(file));
  } catch {
    return new Response("Bad request.", { status: 400 });
  }
  return serveFileRange(p, req);
}
