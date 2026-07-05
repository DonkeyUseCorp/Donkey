/**
 * Bridge between a running chat request and the browser.
 *
 * The chat route holds an open UI-message stream per session. When a
 * provider calls an MCP tool, the proxy POSTs here; we write the tool call
 * into the chat stream (the browser executes it against the editor store
 * and POSTs the result back), then hand the result to the provider.
 */

export interface UIChunkWriter {
  write: (chunk: Record<string, unknown>) => void;
}

interface Waiter {
  resolve: (r: { output?: unknown; errorText?: string }) => void;
  timer: ReturnType<typeof setTimeout>;
}

interface Session {
  writer: UIChunkWriter;
  waiters: Map<string, Waiter>;
}

// Survives dev-server module reloads.
const g = globalThis as unknown as { __veditorAiSessions?: Map<string, Session> };
const sessions = (g.__veditorAiSessions ??= new Map<string, Session>());

export function registerSession(key: string, writer: UIChunkWriter) {
  sessions.set(key, { writer, waiters: new Map() });
}

export function unregisterSession(key: string) {
  const s = sessions.get(key);
  if (s) {
    for (const w of s.waiters.values()) {
      clearTimeout(w.timer);
      w.resolve({ errorText: "The chat request ended before the tool finished." });
    }
  }
  sessions.delete(key);
}

const TOOL_TIMEOUT_MS = 120_000; // subtitles generation can take a while

/**
 * Forward a tool call to the browser via the chat stream and wait for the
 * result. Returns { output } or { errorText }.
 */
export function callBrowserTool(
  sessionKey: string,
  toolName: string,
  input: unknown
): Promise<{ output?: unknown; errorText?: string }> {
  const session = sessions.get(sessionKey);
  if (!session) {
    return Promise.resolve({ errorText: "No live editor session for this chat." });
  }
  const toolCallId = crypto.randomUUID().slice(0, 12);
  session.writer.write({ type: "tool-input-available", toolCallId, toolName, input });
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      session.waiters.delete(toolCallId);
      const errorText = `The editor did not answer the ${toolName} call in time.`;
      session.writer.write({ type: "tool-output-error", toolCallId, errorText });
      resolve({ errorText });
    }, TOOL_TIMEOUT_MS);
    session.waiters.set(toolCallId, {
      timer,
      resolve: (r) => {
        if (r.errorText !== undefined) {
          session.writer.write({ type: "tool-output-error", toolCallId, errorText: r.errorText });
        } else {
          session.writer.write({ type: "tool-output-available", toolCallId, output: r.output ?? null });
        }
        resolve(r);
      },
    });
  });
}

/** Called by /api/cut/ai/tool-result when the browser finishes a tool. */
export function resolveBrowserTool(
  sessionKey: string,
  toolCallId: string,
  result: { output?: unknown; errorText?: string }
): boolean {
  const session = sessions.get(sessionKey);
  const waiter = session?.waiters.get(toolCallId);
  if (!session || !waiter) return false;
  session.waiters.delete(toolCallId);
  clearTimeout(waiter.timer);
  waiter.resolve(result);
  return true;
}
