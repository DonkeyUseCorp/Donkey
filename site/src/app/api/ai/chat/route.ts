import { spawn } from "node:child_process";
import os from "node:os";
import path from "node:path";
import { query } from "@anthropic-ai/claude-agent-sdk";
import { createUIMessageStream, createUIMessageStreamResponse, type UIMessage } from "ai";

export const runtime = "nodejs";

import { callBrowserTool, registerSession, unregisterSession, type UIChunkWriter } from "@/cut/server/ai/bridge";
import { systemPrompt } from "@/cut/server/ai/catalog";

interface ChatBody {
  messages: UIMessage[];
  model: string;
  context?: unknown;
  /** Provider-native session/thread id from the previous turn, if any. */
  providerSession?: string;
}

// Cut lives under site/src/cut; the proxy is spawned by filesystem path (not
// imported/bundled), so it is resolved from the dev cwd (site/) to its source.
const proxyPath = () =>
  path.join(process.cwd(), "src", "cut", "server", "ai", "mcp-proxy.mjs");

function lastUserText(messages: UIMessage[]): string {
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i];
    if (m.role !== "user") continue;
    return m.parts
      .map((p) => (p.type === "text" ? p.text : ""))
      .join("")
      .trim();
  }
  return "";
}

/** Asset refs the user dragged into the chat with the last message. */
function lastUserAttachments(messages: UIMessage[]): unknown[] {
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i];
    if (m.role !== "user") continue;
    const meta = (m as { metadata?: { attachments?: unknown } }).metadata;
    return Array.isArray(meta?.attachments) ? meta.attachments : [];
  }
  return [];
}

export async function POST(req: Request) {
  const body = (await req.json()) as ChatBody;
  const base = new URL(req.url).origin;
  const sessionKey = crypto.randomUUID();
  const userText = lastUserText(body.messages);
  const attachments = lastUserAttachments(body.messages);
  const attachBlock = attachments.length
    ? `\n\n<attached_assets>\nThe user attached these project media assets to this message (ids are usable with the editor tools):\n${JSON.stringify(attachments)}\n</attached_assets>`
    : "";
  const prompt = `${userText}${attachBlock}\n\n<editor_state>\n${JSON.stringify(body.context ?? {})}\n</editor_state>`;

  const stream = createUIMessageStream({
    execute: async ({ writer }) => {
      const emit: UIChunkWriter["write"] = (chunk) =>
        writer.write(chunk as Parameters<typeof writer.write>[0]);
      registerSession(sessionKey, { write: emit });
      emit({ type: "start" });
      // The browser posts tool outputs back to /api/ai/tool-result with this key.
      emit({ type: "data-session", data: { sessionKey }, transient: true });
      try {
        if (body.model.startsWith("claude")) {
          await runClaude(emit, prompt, body, base, sessionKey, req.signal);
        } else if (body.model === "cut-test") {
          await runFake(emit, sessionKey, userText);
        } else {
          await runCodex(emit, prompt, body, base, sessionKey, req.signal);
        }
      } catch (err) {
        emit({ type: "error", errorText: err instanceof Error ? err.message : String(err) });
      } finally {
        unregisterSession(sessionKey);
        emit({ type: "finish" });
      }
    },
  });

  return createUIMessageStreamResponse({ stream });
}

/** Claude models through the Agent SDK — the user's Claude Code login. */
async function runClaude(
  emit: UIChunkWriter["write"],
  prompt: string,
  body: ChatBody,
  base: string,
  sessionKey: string,
  signal: AbortSignal
) {
  const q = query({
    prompt,
    options: {
      model: body.model,
      ...(body.providerSession ? { resume: body.providerSession } : {}),
      systemPrompt: systemPrompt(),
      tools: [], // no built-in tools — the editor MCP server is the whole surface
      mcpServers: {
        cut: {
          type: "stdio",
          command: process.execPath,
          args: [proxyPath(), base, sessionKey],
          alwaysLoad: true,
        },
      },
      allowedTools: ["mcp__cut"],
      permissionMode: "dontAsk",
      settingSources: [], // don't drag the user's CLAUDE.md/settings into app chats
      includePartialMessages: true,
      maxTurns: 30,
      cwd: os.tmpdir(),
    },
  });
  const onAbort = () => void q.interrupt().catch(() => {});
  signal.addEventListener("abort", onAbort);

  let textCount = 0;
  let textId: string | null = null;
  try {
    for await (const msg of q) {
      const m = msg as unknown as Record<string, unknown> & { type: string };
      if (m.type === "system" && m.subtype === "init") {
        emit({ type: "data-session", data: { providerSession: m.session_id }, transient: true });
      } else if (m.type === "stream_event") {
        const ev = m.event as {
          type: string;
          content_block?: { type: string };
          delta?: { type: string; text?: string };
        };
        if (ev.type === "content_block_start" && ev.content_block?.type === "text") {
          textId = `t${++textCount}`;
          emit({ type: "text-start", id: textId });
        } else if (ev.type === "content_block_delta" && ev.delta?.type === "text_delta" && textId) {
          emit({ type: "text-delta", id: textId, delta: ev.delta.text ?? "" });
        } else if (ev.type === "content_block_stop" && textId) {
          emit({ type: "text-end", id: textId });
          textId = null;
        }
      } else if (m.type === "result" && m.subtype !== "success") {
        const detail = typeof m.result === "string" ? m.result : String(m.subtype);
        emit({ type: "error", errorText: `Claude stopped: ${detail}` });
      }
    }
  } finally {
    signal.removeEventListener("abort", onAbort);
    if (textId) emit({ type: "text-end", id: textId });
  }
}

/** GPT models through the Codex CLI — the user's ChatGPT login. */
async function runCodex(
  emit: UIChunkWriter["write"],
  prompt: string,
  body: ChatBody,
  base: string,
  sessionKey: string,
  signal: AbortSignal
) {
  const args = ["exec"];
  if (body.providerSession) args.push("resume", body.providerSession);
  args.push(
    "--json",
    "--skip-git-repo-check",
    "--sandbox",
    "read-only",
    "-m",
    body.model,
    "-C",
    os.tmpdir(),
    "-c",
    `mcp_servers.cut.command=${JSON.stringify(process.execPath)}`,
    "-c",
    `mcp_servers.cut.args=${JSON.stringify([proxyPath(), base, sessionKey])}`,
    body.providerSession ? prompt : `${systemPrompt()}\n\n${prompt}`
  );

  await new Promise<void>((resolve, reject) => {
    // stdin must be closed: `codex exec` otherwise waits on it for EOF.
    const proc = spawn("codex", args, { env: process.env, stdio: ["ignore", "pipe", "pipe"] });
    const onAbort = () => proc.kill("SIGTERM");
    signal.addEventListener("abort", onAbort);

    let textCount = 0;
    let stdoutBuf = "";
    let stderrTail = "";
    proc.stdout.setEncoding("utf8");
    proc.stdout.on("data", (chunk: string) => {
      stdoutBuf += chunk;
      let nl;
      while ((nl = stdoutBuf.indexOf("\n")) !== -1) {
        const line = stdoutBuf.slice(0, nl).trim();
        stdoutBuf = stdoutBuf.slice(nl + 1);
        if (!line) continue;
        let ev: { type?: string; thread_id?: string; message?: string; item?: { type?: string; text?: string }; error?: { message?: string } };
        try {
          ev = JSON.parse(line);
        } catch {
          continue;
        }
        if (ev.type === "thread.started" && ev.thread_id) {
          emit({ type: "data-session", data: { providerSession: ev.thread_id }, transient: true });
        } else if (ev.type === "item.completed" && ev.item?.type === "agent_message" && ev.item.text) {
          const id = `t${++textCount}`;
          emit({ type: "text-start", id });
          emit({ type: "text-delta", id, delta: ev.item.text });
          emit({ type: "text-end", id });
        } else if (ev.type === "error" || ev.type === "turn.failed") {
          const message = ev.error?.message ?? ev.message ?? "Codex failed.";
          emit({ type: "error", errorText: message });
        }
      }
    });
    proc.stderr.on("data", (d: Buffer) => {
      stderrTail = (stderrTail + d.toString()).slice(-2000);
    });
    proc.on("error", (err) => {
      signal.removeEventListener("abort", onAbort);
      reject(
        err.message.includes("ENOENT")
          ? new Error("Codex CLI not found — install it with: npm i -g @openai/codex")
          : err
      );
    });
    proc.on("close", (code) => {
      signal.removeEventListener("abort", onAbort);
      if (code !== 0 && !signal.aborted && code !== null) {
        const tail = stderrTail.trim().split("\n").slice(-2).join(" ");
        emit({ type: "error", errorText: `Codex exited with code ${code}. ${tail}`.trim() });
      }
      resolve();
    });
  });
}

/**
 * Hermetic provider for tests: exercises the exact same bridge path
 * (context → tool round-trips through the browser → streamed reply)
 * without spending any tokens.
 */
async function runFake(emit: UIChunkWriter["write"], sessionKey: string, userText: string) {
  const say = (id: string, text: string) => {
    emit({ type: "text-start", id });
    emit({ type: "text-delta", id, delta: text });
    emit({ type: "text-end", id });
  };
  emit({ type: "data-session", data: { providerSession: "test-thread" }, transient: true });
  if (/first frame/i.test(userText)) {
    const r = await callBrowserTool(sessionKey, "freeze_frame", { duration: 1 });
    say("t1", r.errorText ? `Tool failed: ${r.errorText}` : "Done: FREEZEMARK frame pinned to the start.");
    return;
  }
  say("t1", "Let me check what's selected.");
  const st = await callBrowserTool(sessionKey, "get_state", {});
  if (st.errorText !== undefined) {
    emit({ type: "error", errorText: st.errorText });
    return;
  }
  const state = st.output as {
    selection?: { kind: string; id: string } | null;
  };
  if (state.selection?.kind === "text") {
    const r = await callBrowserTool(sessionKey, "update_title", {
      id: state.selection.id,
      text: "TESTMARK improved",
      color: "#FFD60A",
    });
    say("t2", r.errorText ? `Tool failed: ${r.errorText}` : "Done: TESTMARK applied to your title.");
  } else {
    const r = await callBrowserTool(sessionKey, "add_title", { text: "TESTMARK title" });
    say("t2", r.errorText ? `Tool failed: ${r.errorText}` : "Done: TESTMARK title added.");
  }
}
