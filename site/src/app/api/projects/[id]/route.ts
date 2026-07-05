import { NextResponse } from "next/server";
import type { ProjectDoc } from "@/cut/lib/types";
import { deleteProject, readProject, writeProject } from "@/cut/server/projects";

export const runtime = "nodejs";

type Ctx = { params: Promise<{ id: string }> };

export async function GET(_req: Request, { params }: Ctx) {
  const { id } = await params;
  const doc = await readProject(id).catch(() => null);
  if (!doc) return NextResponse.json({ error: "Project not found." }, { status: 404 });
  return NextResponse.json(doc);
}

export async function PUT(req: Request, { params }: Ctx) {
  const { id } = await params;
  try {
    const existing = await readProject(id);
    if (!existing) return NextResponse.json({ error: "Project not found." }, { status: 404 });
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
        body.ui && typeof body.ui === "object"
          ? { ...existing.ui, ...body.ui }
          : existing.ui,
      publish:
        body.publish && typeof body.publish === "object"
          ? { ...existing.publish, ...body.publish }
          : existing.publish,
    };
    await writeProject(id, doc);
    return NextResponse.json({ ok: true, updatedAt: doc.updatedAt });
  } catch (err) {
    return NextResponse.json(
      { error: err instanceof Error ? err.message : "Could not save project." },
      { status: 500 }
    );
  }
}

export async function DELETE(_req: Request, { params }: Ctx) {
  const { id } = await params;
  try {
    await deleteProject(id);
    return NextResponse.json({ ok: true });
  } catch (err) {
    return NextResponse.json(
      { error: err instanceof Error ? err.message : "Could not delete project." },
      { status: 500 }
    );
  }
}
