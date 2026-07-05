import { NextResponse } from "next/server";
import { createProject, listProjects } from "@/cut/server/projects";

export const runtime = "nodejs";

export async function GET() {
  return NextResponse.json(await listProjects());
}

export async function POST(req: Request) {
  try {
    const { name } = (await req.json()) as { name?: string };
    const project = await createProject(name ?? "Untitled");
    return NextResponse.json(project);
  } catch (err) {
    return NextResponse.json(
      { error: err instanceof Error ? err.message : "Could not create project." },
      { status: 500 }
    );
  }
}
