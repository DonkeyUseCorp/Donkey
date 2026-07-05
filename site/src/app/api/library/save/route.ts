import { NextResponse } from "next/server";
import { addFromProject } from "@/cut/server/library";

export const runtime = "nodejs";

/** Copy a project media file into the shared library. */
export async function POST(req: Request) {
  try {
    const { projectId, fileName, name } = (await req.json()) as {
      projectId: string;
      fileName: string;
      name?: string;
    };
    return NextResponse.json(await addFromProject(projectId, fileName, name ?? fileName));
  } catch (err) {
    return NextResponse.json(
      { error: err instanceof Error ? err.message : "Could not save to library." },
      { status: 500 }
    );
  }
}
