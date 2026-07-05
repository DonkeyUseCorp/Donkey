import { libMediaPath } from "@/cut/server/library";
import { serveFileRange } from "@/cut/server/serveFile";

export const runtime = "nodejs";

/** Serve a raw library media file with Range support. */
export async function GET(
  req: Request,
  { params }: { params: Promise<{ file: string }> }
) {
  const { file } = await params;
  let p: string;
  try {
    p = libMediaPath(decodeURIComponent(file));
  } catch {
    return new Response("Bad request.", { status: 400 });
  }
  return serveFileRange(p, req);
}
