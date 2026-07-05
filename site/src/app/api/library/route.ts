import { NextResponse } from "next/server";
import { addUpload, listLibrary } from "@/cut/server/library";

export const runtime = "nodejs";
export const maxDuration = 300;

export async function GET() {
  return NextResponse.json(await listLibrary());
}

export async function POST(req: Request) {
  try {
    const form = await req.formData();
    const file = form.get("file");
    if (!(file instanceof File)) {
      return NextResponse.json({ error: "No file in upload." }, { status: 400 });
    }
    return NextResponse.json(await addUpload(file));
  } catch (err) {
    return NextResponse.json(
      { error: err instanceof Error ? err.message : "Upload failed." },
      { status: 500 }
    );
  }
}
