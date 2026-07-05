#!/usr/bin/env node
/**
 * Minimal stdio MCP server that proxies Cut's editor tools.
 *
 * Spawned by whichever model harness is chatting (Claude Agent SDK or the
 * Codex CLI). Speaks newline-delimited JSON-RPC on stdio and forwards
 * tools/list + tools/call to the local Next server, which routes execution
 * into the user's open editor tab.
 *
 *   usage: node mcp-proxy.mjs <baseUrl> <sessionKey>
 */

const [, , BASE = "http://localhost:3000", SESSION = ""] = process.argv;

let buffer = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buffer += chunk;
  let nl;
  while ((nl = buffer.indexOf("\n")) !== -1) {
    const line = buffer.slice(0, nl).trim();
    buffer = buffer.slice(nl + 1);
    if (line) void handle(line);
  }
});
process.stdin.on("end", () => process.exit(0));

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + "\n");
}

async function handle(line) {
  let req;
  try {
    req = JSON.parse(line);
  } catch {
    return;
  }
  const { id, method, params } = req;
  const reply = (result) => id !== undefined && send({ jsonrpc: "2.0", id, result });
  const fail = (message) =>
    id !== undefined && send({ jsonrpc: "2.0", id, error: { code: -32000, message } });

  try {
    if (method === "initialize") {
      reply({
        protocolVersion: params?.protocolVersion ?? "2024-11-05",
        capabilities: { tools: {} },
        serverInfo: { name: "cut", version: "1.0.0" },
      });
    } else if (method === "notifications/initialized" || method === "notifications/cancelled") {
      // notifications: no response
    } else if (method === "ping") {
      reply({});
    } else if (method === "tools/list") {
      const res = await fetch(`${BASE}/api/ai/proxy?type=catalog`);
      const { tools } = await res.json();
      reply({ tools });
    } else if (method === "tools/call") {
      const res = await fetch(`${BASE}/api/ai/proxy`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          sessionKey: SESSION,
          name: params?.name,
          args: params?.arguments ?? {},
        }),
      });
      const body = await res.json();
      reply(body); // { content: [...], isError? } — already MCP-shaped
    } else if (id !== undefined) {
      send({ jsonrpc: "2.0", id, error: { code: -32601, message: `Unknown method ${method}` } });
    }
  } catch (err) {
    fail(err instanceof Error ? err.message : String(err));
  }
}
