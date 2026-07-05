import { execFile } from "node:child_process";
import os from "node:os";
import path from "node:path";

import { findOnPath } from "../server/util";

/** Directories a GUI-spawned process misses but user CLIs commonly live in. */
const COMMON_BIN_DIRS = [
  "/opt/homebrew/bin",
  "/usr/local/bin",
  path.join(os.homedir(), ".local", "bin"),
  path.join(os.homedir(), ".bun", "bin"),
  path.join(os.homedir(), ".npm-global", "bin"),
  "/usr/bin",
  "/bin",
  "/usr/sbin",
  "/sbin",
];

function loginShellPath(): Promise<string | null> {
  return new Promise((resolve) => {
    // Login (non-interactive) shell: runs .zprofile, where PATH is usually
    // set, without the hang risk of interactive rc files.
    execFile(
      "/bin/zsh",
      ["-lc", 'printf %s "$PATH"'],
      { timeout: 4000 },
      (err, stdout) => resolve(err ? null : stdout.trim() || null)
    );
  });
}

/**
 * The engine is spawned by an app, not a terminal, so it inherits a bare
 * PATH. Rebuild it: the app's bundled tools first (bundled tool always wins),
 * then the user's login-shell PATH, common install dirs, and whatever was
 * already there.
 */
export async function widenPath(): Promise<void> {
  const parts: string[] = [];
  const push = (p?: string | null) => {
    if (!p) return;
    for (const dir of p.split(":")) {
      if (dir && !parts.includes(dir)) parts.push(dir);
    }
  };
  push(process.env.DONKEY_CUT_TOOLS_DIR);
  push(await loginShellPath());
  for (const dir of COMMON_BIN_DIRS) push(dir);
  push(process.env.PATH);
  process.env.PATH = parts.join(":");
}

/** First executable named `name` on the (widened) PATH, or null. */
export const resolveOnPath = findOnPath;
