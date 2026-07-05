import { NextResponse } from "next/server";
import { listExports } from "@/cut/server/projects";

export const runtime = "nodejs";

/** Rendered exports for a project, newest first. */
export async function GET(_req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  try {
    return NextResponse.json(await listExports(id));
  } catch {
    return NextResponse.json({ error: "Invalid project." }, { status: 400 });
  }
}
