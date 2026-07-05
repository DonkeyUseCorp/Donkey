import { NextResponse } from "next/server";

export const runtime = "nodejs";

import { callBrowserTool } from "@/cut/server/ai/bridge";
import { AI_SKILL_INDEX, AI_SKILLS, AI_TOOLS } from "@/cut/server/ai/catalog";
import { hostedApiBlock } from "@/cut/server/local-only";

/** MCP-shaped tool catalog for the stdio proxy. */
export async function GET(req: Request) {
  const blocked = hostedApiBlock();
  if (blocked) return blocked;
  const type = new URL(req.url).searchParams.get("type");
  if (type !== "catalog") return NextResponse.json({ error: "Bad request." }, { status: 400 });
  return NextResponse.json({
    tools: AI_TOOLS.map((t) => ({
      name: t.name,
      description: t.description,
      inputSchema: t.inputSchema,
    })),
  });
}

const text = (value: unknown) => ({
  content: [{ type: "text", text: typeof value === "string" ? value : JSON.stringify(value) }],
});

/** Execute one tool call: server-side skills directly, editor tools via the browser. */
export async function POST(req: Request) {
  const blocked = hostedApiBlock();
  if (blocked) return blocked;
  const { sessionKey, name, args } = (await req.json()) as {
    sessionKey?: string;
    name?: string;
    args?: Record<string, unknown>;
  };
  const def = AI_TOOLS.find((t) => t.name === name);
  if (!name || !def) {
    return NextResponse.json({ ...text(`Unknown tool: ${name}`), isError: true });
  }

  if (def.server) {
    if (name === "list_skills") return NextResponse.json(text({ skills: AI_SKILL_INDEX }));
    if (name === "read_skill") {
      const doc = AI_SKILLS[String(args?.name ?? "")];
      return doc
        ? NextResponse.json(text(doc))
        : NextResponse.json({ ...text(`No such skill. Available: ${AI_SKILL_INDEX.join(", ")}`), isError: true });
    }
  }

  const result = await callBrowserTool(String(sessionKey ?? ""), name, args ?? {});
  if (result.errorText !== undefined) {
    return NextResponse.json({ ...text(result.errorText), isError: true });
  }
  // Screenshots come back as data URLs; hand them to the model as images.
  const out = result.output as { image?: string } | undefined;
  if (name === "capture_frame" && out?.image?.startsWith("data:image/")) {
    const [head, data] = out.image.split(",", 2);
    const mimeType = head.slice(5, head.indexOf(";"));
    return NextResponse.json({ content: [{ type: "image", data, mimeType }] });
  }
  return NextResponse.json(text(result.output ?? { ok: true }));
}
