import { NextResponse } from "next/server";

export const runtime = "nodejs";

import { resolveBrowserTool } from "@/cut/server/ai/bridge";
import { hostedApiBlock } from "@/cut/server/local-only";

/** The browser posts tool outputs here after executing them on the store. */
export async function POST(req: Request) {
  const blocked = hostedApiBlock();
  if (blocked) return blocked;
  const { sessionKey, toolCallId, output, errorText } = (await req.json()) as {
    sessionKey?: string;
    toolCallId?: string;
    output?: unknown;
    errorText?: string;
  };
  if (!sessionKey || !toolCallId) {
    return NextResponse.json({ error: "sessionKey and toolCallId required." }, { status: 400 });
  }
  const ok = resolveBrowserTool(sessionKey, toolCallId, { output, errorText });
  return NextResponse.json({ ok });
}
