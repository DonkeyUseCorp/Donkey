import Foundation

/// What a single sandboxed spawn is allowed to touch on the filesystem. The runtime builds one of
/// these per task-work spawn (shell command, bundled tool, ffmpeg) from the conversation's workspace
/// and declared inputs; `WorkspaceSandbox` turns it into a seatbelt profile that the kernel enforces.
///
/// The policy carries the per-task data: where the child may WRITE (its workspace folder, plus any
/// location the user approved), and — for tools that read locked — which outside files it may READ. The
/// process-global read roots a tool needs merely to launch (system frameworks, the dyld cache, the dirs
/// on the child's PATH) come from the profile builder, so a caller never has to know them.
public struct SandboxPolicy: Sendable, Equatable {
    /// Directories the child may read AND write — the conversation's workspace folder, plus anywhere a
    /// consent prompt already approved. A write outside these is denied by the kernel (EPERM).
    public var writableRoots: [String]
    /// Files/directories the child may READ when `allowAllReads` is false — the task's declared inputs.
    /// Read-only: an input is something to act on, not write back. Ignored when `allowAllReads` is true.
    public var readableRoots: [String]
    /// Whether the child may use the network. True for now: API calls and downloads are common, and the
    /// egress tools that could exfiltrate (curl, scp, python) are gated by the shell consent classifier.
    public var allowNetwork: Bool
    /// When true the child may READ anywhere on disk and `readableRoots` is unused. Shell commands set
    /// this: the consent classifier already treats reads as free, so locking them only broke legitimate
    /// file-finding. Bundled-tool pipelines leave it false — a possibly-hostile input file should not let
    /// its tool read the rest of the disk, so those stay limited to `readableRoots`.
    public var allowAllReads: Bool

    public init(
        writableRoots: [String],
        readableRoots: [String] = [],
        allowNetwork: Bool = true,
        allowAllReads: Bool = false
    ) {
        self.writableRoots = writableRoots
        self.readableRoots = readableRoots
        self.allowNetwork = allowNetwork
        self.allowAllReads = allowAllReads
    }

    /// Policy for an orchestrator that runs a bundled tool on workspace files: confine writes to the
    /// workspace working directory (plus `alsoWritable` — e.g. the directory of an output the user asked
    /// to write in place) and allow reads of the named input file(s). Reads stay locked to those inputs.
    /// `nil` when there is no real workspace base (the working directory fell back to home), so the tool
    /// runs unconfined.
    public static func forWorkspace(
        baseDirectory: String?,
        readableInputs: [String] = [],
        alsoWritable: [String] = []
    ) -> SandboxPolicy? {
        guard let base = baseDirectory, !base.isEmpty else { return nil }
        return SandboxPolicy(
            writableRoots: ([base] + alsoWritable).filter { !$0.isEmpty },
            readableRoots: readableInputs.filter { !$0.isEmpty },
            allowNetwork: true
        )
    }

    /// Policy for an orchestrator whose input is a single local source that may sit outside the workspace —
    /// confine writes to the workspace and allow reading the source when it exists on disk. A URL source
    /// downloads into the folder and so needs no read rule. Shared by the caption and shorts pipelines.
    public static func forWorkspace(baseDirectory: String?, localSource: String) -> SandboxPolicy? {
        let named = (localSource as NSString).expandingTildeInPath
        let reads = FileManager.default.fileExists(atPath: named) ? [named] : []
        return forWorkspace(baseDirectory: baseDirectory, readableInputs: reads)
    }
}

/// Wraps a spawned process in a macOS seatbelt (`sandbox-exec`) profile so the kernel confines the
/// agent's untrusted tools to the directories the policy names — its workspace folder, plus anywhere a
/// consent prompt already approved.
///
/// This is the safety boundary for the UNTRUSTED spawn surface only — arbitrary shell commands and
/// bundled tools the planner composes. It does not (and cannot) confine the app's own in-process file
/// writes (`files.write`); `sandbox-exec` confines children, and the in-process equivalent would jail
/// the whole app. Those writes stay governed by `resolveWritePath`.
///
/// The jail is FILESYSTEM-ONLY: it leaves `network*`, `mach-lookup`, and Apple Events open so API
/// calls, `osascript`, and `open` still work. Non-filesystem side effects remain the job of the shell
/// consent classifier; the jail only removes the question "can this tool escape the folder?".
public enum WorkspaceSandbox {
    /// The OS sandbox wrapper. Deprecated by Apple but functional on every current macOS, and the same
    /// mechanism Chromium uses to confine its helpers. A future hardening step could call `sandbox_init`
    /// from a small spawn helper instead.
    public static let sandboxExecPath = "/usr/bin/sandbox-exec"

    /// Read-only system locations a binary needs merely to launch: dyld and its shared-cache cryptex,
    /// the system frameworks/libraries, resolver and timezone data. Verified empirically — without the
    /// cryptex and `/private/var/db/dyld` entries even `/bin/zsh` aborts under the profile. These are
    /// program/system data, never user documents, so allow-listing them keeps locked-reads intact.
    static let systemReadRoots: [String] = [
        "/usr", "/bin", "/sbin",
        "/System",
        "/Library",
        "/private/etc",                                 // /etc/zshenv, hosts, resolv.conf
        "/private/var/db/dyld",                         // dyld closures
        "/private/var/db/timezone",                     // localtime data
        "/System/Volumes/Preboot/Cryptexes/OS"          // dyld shared cache (the classic omission)
    ]

    /// User cache directories a well-behaved tool writes scratch into: the macOS per-user cache and the
    /// XDG `~/.cache` (yt-dlp's download cache, a tool's compiled-model cache). Allowed for write like the
    /// darwin temp — auto-purgeable, no user documents — so a bundled tool that insists on caching there
    /// doesn't EPERM mid-run. Resolved once; only existing dirs are kept.
    static var userCacheRoots: [String] {
        ["~/Library/Caches", "~/.cache"].compactMap(canonicalIfPresent)
    }

    /// True when this policy will actually confine a spawn — present and naming at least one writable
    /// root. A nil/empty policy means "no workspace yet"; callers spawn unwrapped (see `wrap`).
    public static func isActive(_ policy: SandboxPolicy?) -> Bool {
        guard let policy else { return false }
        return policy.writableRoots.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Wrap an executable + arguments into the `sandbox-exec` invocation that runs them under `policy`.
    /// `policy == nil` (or inactive) returns the inputs UNCHANGED — fail-open. With no owned folder
    /// there is nothing to contain, and refusing every spawn would brick the agent on its first step;
    /// in practice the workspace root is created before the first tool runs, so task work is confined.
    /// `environment["PATH"]` and `bundledToolsDir` supply the program dirs the profile must allow for
    /// reads, so they match exactly what the child can execute.
    public static func wrap(
        executable: URL,
        arguments: [String],
        policy: SandboxPolicy?,
        environment: [String: String],
        bundledToolsDir: String?
    ) -> (executable: URL, arguments: [String]) {
        guard let policy, isActive(policy) else { return (executable, arguments) }
        let sbpl = profile(for: policy, programPath: environment["PATH"] ?? "", bundledToolsDir: bundledToolsDir)
        let args = ["-p", sbpl, "--", executable.path] + arguments
        return (URL(fileURLWithPath: sandboxExecPath), args)
    }

    /// The child environment for a sandboxed spawn: corral `TMPDIR` into `<jail>/.tmp` so well-behaved
    /// tools' scratch files stay inside the folder (and are cleaned with it). The profile separately
    /// allows the real per-user darwin temp for tools that ignore `TMPDIR` (`mkstemp`/`confstr`). A nil
    /// or inactive policy returns `base` unchanged.
    public static func childEnvironment(_ base: [String: String], policy: SandboxPolicy?) -> [String: String] {
        guard isActive(policy), let jail = policy?.writableRoots.first(where: { !$0.isEmpty }) else { return base }
        var environment = base
        let tmp = canonical(jail) + "/.tmp"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        environment["TMPDIR"] = tmp
        return environment
    }

    /// Build the seatbelt profile (SBPL) string for `policy`. `programPath` is the child's `PATH`
    /// (its dirs are allowed for read so binaries can be loaded); `bundledToolsDir` holds the bundled
    /// binaries + `libpdfium.dylib`. Every path is canonicalized (symlinks resolved) because the kernel
    /// matches subpaths on the real path — a workspace under `/tmp` or `/var` would otherwise fail to
    /// match its own write rule.
    public static func profile(for policy: SandboxPolicy, programPath: String, bundledToolsDir: String?) -> String {
        let writable = uniqued(policy.writableRoots.compactMap(canonicalIfPresent))
        let inputs = uniqued(policy.readableRoots.compactMap(canonicalIfPresent))

        var readRoots = systemReadRoots + programReadRoots(programPath)
        if let bundledToolsDir, let resolved = canonicalIfPresent(bundledToolsDir) { readRoots.append(resolved) }
        readRoots = uniqued(readRoots)

        let darwinTemp = canonical(NSTemporaryDirectory())

        var lines: [String] = [
            "(version 1)",
            "(deny default)",
            "(allow process-fork) (allow process-exec*)",
            "(allow sysctl-read) (allow mach-lookup) (allow signal (target self))",
            "(allow ipc-posix-shm*)",
            "(allow file-read-metadata)"
        ]
        if policy.allowNetwork { lines.append("(allow network*)") }

        // Reads. Shell commands (allowAllReads) may read anywhere — the consent classifier already treats
        // reads as free, so the agent can inspect files the user pointed it at. Bundled-tool pipelines stay
        // locked to system + program dirs + the task's declared inputs, so a hostile input file can't make
        // its tool read the rest of the disk. Directory listing/stat is covered globally by
        // file-read-metadata, so an input's siblings stay unreadable.
        if policy.allowAllReads {
            lines.append("(allow file-read* (subpath \"/\"))")
        } else {
            lines.append("(allow file-read* (literal \"/\")")
            for path in readRoots { lines.append("  (subpath \(quote(path)))") }
            for path in inputs { lines.append("  (subpath \(quote(path)))") }
            lines.append(")")
        }

        // Writes: the workspace folder(s) plus any consent-approved location, the per-user darwin temp and
        // user cache dirs (sanctioned scratch outside the jail — auto-purged, hold no user documents so a
        // tool's model/compile cache lands somewhere), and /dev pseudo-devices.
        lines.append("(allow file-read* file-write*")
        lines.append("  (subpath \"/dev\")")
        lines.append("  (subpath \(quote(darwinTemp)))")
        for path in userCacheRoots { lines.append("  (subpath \(quote(path)))") }
        for path in writable { lines.append("  (subpath \(quote(path)))") }
        lines.append(")")

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Read-only program directories from the child's PATH (`/opt/homebrew/bin`, `/usr/local/bin`, a
    /// version manager's shims, the bundled-tools dir/overlay). Without these a binary on PATH cannot
    /// be loaded under a locked-reads profile. Only existing absolute directories are kept; they are
    /// program dirs, not user data.
    private static func programReadRoots(_ programPath: String) -> [String] {
        programPath
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0.hasPrefix("/") }
            .compactMap(canonicalIfPresent)
    }

    /// Canonical absolute path with all symlinks resolved (`/var` → `/private/var`), via `realpath`.
    /// The kernel evaluates sandbox subpaths against the real path, so rules must use it too. Returns
    /// the tilde-expanded input unchanged when the path does not exist (realpath fails).
    static func canonical(_ path: String) -> String {
        canonicalIfPresent(path) ?? (path as NSString).expandingTildeInPath
    }

    /// Canonical path, or nil if it does not exist on disk — so non-existent allow-list entries are
    /// dropped rather than emitted as un-resolvable rules. `realpath` allocates the result buffer.
    private static func canonicalIfPresent(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.isEmpty, let resolved = realpath(expanded, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Order-preserving dedupe (the profile is more readable without repeated subpaths, and identical
    /// rules are pointless).
    private static func uniqued(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// Quote a path as an SBPL string literal, escaping backslash and double-quote.
    private static func quote(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
