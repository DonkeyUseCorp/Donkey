import { exportPath } from "@/cut/server/projects";
import { serveFileRange } from "@/cut/server/serveFile";

export const runtime = "nodejs";

/** Serve a rendered export from the project folder, with Range support so
 * the platform-preview player can seek. */
export async function GET(
  req: Request,
  { params }: { params: Promise<{ id: string; file: string }> }
) {
  const { id, file } = await params;
  let p: string;
  try {
    p = exportPath(id, decodeURIComponent(file));
  } catch {
    return new Response("Bad request.", { status: 400 });
  }
  return serveFileRange(p, req, { contentType: "video/mp4" });
}
