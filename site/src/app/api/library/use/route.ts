import { NextResponse } from "next/server";
import { useInProject } from "@/cut/server/library";

export const runtime = "nodejs";

/** Copy a library asset into a project's media folder. */
export async function POST(req: Request) {
  try {
    const { assetId, projectId } = (await req.json()) as {
      assetId: string;
      projectId: string;
    };
    const fileName = await useInProject(assetId, projectId);
    return NextResponse.json({ fileName });
  } catch (err) {
    return NextResponse.json(
      { error: err instanceof Error ? err.message : "Could not add from library." },
      { status: 500 }
    );
  }
}
