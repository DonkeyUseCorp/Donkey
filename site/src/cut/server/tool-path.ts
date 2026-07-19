import { execFile } from "node:child_process";
import os from "node:os";
import path from "node:path";

import { exists, findOnPath } from "./util";

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

/** The repo's vendor/donkey-tools when running from a source checkout (the
 * Next dev server and `engine:dev` both run with cwd = site/). The packaged
 * app has no such directory, so this resolves to nothing there. */
async function devVendorToolsDir(): Promise<string | null> {
  const dir = path.resolve(process.cwd(), "..", "vendor", "donkey-tools");
  return (await exists(dir)) ? dir : null;
}

async function widenPath(): Promise<void> {
  const parts: string[] = [];
  const push = (p?: string | null) => {
    if (!p) return;
    for (const dir of p.split(":")) {
      if (dir && !parts.includes(dir)) parts.push(dir);
    }
  };
  push(path.dirname(process.execPath));
  push(process.env.DONKEY_CUT_TOOLS_DIR);
  push(await devVendorToolsDir());
  push(await loginShellPath());
  for (const dir of COMMON_BIN_DIRS) push(dir);
  push(process.env.PATH);
  process.env.PATH = parts.join(":");
}

let widened: Promise<void> | null = null;

/**
 * Rebuild PATH so bundled tools (yt-dlp, ffmpeg, …) resolve identically on
 * every Cut API surface: tools shipped beside the engine binary first (they
 * version with the app), then the app's bundled tools (bundled tool always
 * wins), the repo's vendor tools in dev, the user's login-shell PATH, common
 * install dirs, and whatever was already there. Memoized — the engine runs it
 * at startup, the Next dev server on the first API request.
 */
export function ensureToolPath(): Promise<void> {
  widened ??= widenPath();
  return widened;
}

/** First executable named `name` on the (widened) PATH, or null. */
export const resolveOnPath = findOnPath;
