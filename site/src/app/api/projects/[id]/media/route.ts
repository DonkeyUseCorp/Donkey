import { NextResponse } from "next/server";
import { readProject, saveMedia } from "@/cut/server/projects";

export const runtime = "nodejs";
export const maxDuration = 300;

export async function POST(
  req: Request,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params;
  try {
    if (!(await readProject(id))) {
      return NextResponse.json({ error: "Project not found." }, { status: 404 });
    }
    const form = await req.formData();
    const file = form.get("file");
    if (!(file instanceof File)) {
      return NextResponse.json({ error: "No file in upload." }, { status: 400 });
    }
    const fileName = await saveMedia(id, file);
    return NextResponse.json({ fileName });
  } catch (err) {
    return NextResponse.json(
      { error: err instanceof Error ? err.message : "Upload failed." },
      { status: 500 }
    );
  }
}
