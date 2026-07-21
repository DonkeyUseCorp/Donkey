#!/usr/bin/env node
/**
 * Dev launcher for the stdio MCP proxy: spawned by file path with node from
 * the Next dev server. The engine binary launches the same core via its
 * `mcp-proxy` subcommand instead.
 *
 *   usage: node mcp-proxy.mjs <baseUrl> <sessionKey> <userId>
 */
import { runMcpProxy } from "./mcp-proxy-core.mjs";

const [, , BASE, SESSION, USER] = process.argv;
runMcpProxy(BASE, SESSION, USER);
