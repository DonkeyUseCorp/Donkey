import { execFile } from "node:child_process";
import { NextResponse } from "next/server";

export const runtime = "nodejs";

import { AI_MODELS } from "@/cut/server/ai/models";

function probe(cmd: string, args: string[]): Promise<{ ok: boolean; note: string }> {
  return new Promise((resolve) => {
    execFile(cmd, args, { timeout: 8000 }, (err, stdout, stderr) => {
      if (err) {
        const note = err.message.includes("ENOENT")
          ? `${cmd} is not installed`
          : (stderr || err.message).trim().split("\n")[0];
        resolve({ ok: false, note });
      } else {
        // Some CLIs (codex) report status on stderr.
        resolve({ ok: true, note: (stdout.trim() || stderr.trim()).split("\n")[0] });
      }
    });
  });
}

// Providers rarely change mid-session; cache probes for a minute.
const g = globalThis as unknown as {
  __veditorAiProbe?: { at: number; value: { claude: { ok: boolean; note: string }; codex: { ok: boolean; note: string } } };
};

export async function GET() {
  const cached = g.__veditorAiProbe;
  let value = cached && Date.now() - cached.at < 60_000 ? cached.value : null;
  if (!value) {
    const [claude, codexLogin] = await Promise.all([
      probe("claude", ["--version"]),
      probe("codex", ["login", "status"]),
    ]);
    const codex = codexLogin.ok
      ? /logged in/i.test(codexLogin.note)
        ? { ok: true, note: codexLogin.note }
        : { ok: false, note: "Not signed in — run: codex login" }
      : codexLogin;
    value = { claude, codex };
    g.__veditorAiProbe = { at: Date.now(), value };
  }
  return NextResponse.json({
    models: AI_MODELS,
    providers: {
      claude: { available: value.claude.ok, note: value.claude.note },
      codex: { available: value.codex.ok, note: value.codex.note },
      test: { available: true, note: "hermetic test provider" },
    },
  });
}
