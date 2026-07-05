import { NextResponse } from "next/server";

export const runtime = "nodejs";

import { makeFreezeFrame } from "@/cut/server/frames";
import { readProject } from "@/cut/server/projects";

/** Render a freeze-frame still clip from a media file's frame. */
export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  try {
    if (!(await readProject(id))) {
      return NextResponse.json({ error: "Project not found." }, { status: 404 });
    }
    const body = (await req.json()) as {
      file?: string;
      srcTime?: number;
      duration?: number;
      frame?: { w?: number; h?: number };
      framing?: { fit?: "fit" | "fill"; panX?: number; panY?: number };
    };
    if (!body.file || typeof body.srcTime !== "number") {
      return NextResponse.json({ error: "file and srcTime are required." }, { status: 400 });
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
    return NextResponse.json({
      id: crypto.randomUUID().slice(0, 8),
      fileName: made.fileName,
      name: made.fileName,
      type: "video",
      duration: made.duration,
      width: made.width,
      height: made.height,
    });
  } catch (err) {
    return NextResponse.json(
      { error: err instanceof Error ? err.message : String(err) },
      { status: 500 }
    );
  }
}
