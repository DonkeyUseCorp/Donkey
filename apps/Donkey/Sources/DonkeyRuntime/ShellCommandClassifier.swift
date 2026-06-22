import Foundation

/// Risk tiers for a `shell_exec` command. The tier decides whether the command
/// runs silently, prompts for allow-once/always-allow consent, or prompts every
/// time and can never be blanket-allowed.
///
/// This replaces the old all-or-nothing denylist: nothing is silently refused,
/// but anything that changes state asks first. The classifier matches **argv
/// tokens** (executable, subcommand, flags) — typed/technical fields of a
/// structured command string — never natural-language user intent.
public enum ShellRiskTier: String, Codable, Sendable, Comparable {
    /// Read-only inspection. Runs immediately, no prompt.
    case read
    /// A reversible change to app or system state. Prompts once; the user may
    /// "allow once" or "always allow" the command signature.
    case reversibleWrite
    /// Destructive, privileged, or network-egress. Prompts every time and is
    /// never eligible for "always allow".
    case highRisk

    private var order: Int {
        switch self {
        case .read: return 0
        case .reversibleWrite: return 1
        case .highRisk: return 2
        }
    }

    public static func < (lhs: ShellRiskTier, rhs: ShellRiskTier) -> Bool {
        lhs.order < rhs.order
    }
}

/// The result of classifying a one-line shell command.
public struct ShellCommandClassification: Sendable, Equatable {
    /// The most restrictive tier across every segment of the command.
    public var tier: ShellRiskTier
    /// A normalized `executable [subcommand]` signature that a prompt and an
    /// "always allow" rule key on (e.g. `defaults write`, `open`, `mdfind`).
    /// Taken from the segment that set the overall tier.
    public var signature: String
    /// Short, human-readable reason the deciding segment landed in its tier,
    /// surfaced in the consent prompt (e.g. "deletes files").
    public var reason: String?

    public init(tier: ShellRiskTier, signature: String, reason: String? = nil) {
        self.tier = tier
        self.signature = signature
        self.reason = reason
    }
}

/// Classifies `shell_exec` commands into risk tiers by inspecting argv tokens.
public enum ShellCommandClassifier {

    // MARK: - Public API

    /// Classify a one-line command. The overall tier is the most restrictive
    /// across all pipeline/substitution segments (so `mdfind x | xargs rm`
    /// classifies as `highRisk`), and the returned signature/reason come from
    /// the segment that set that tier.
    public static func classify(_ command: String) -> ShellCommandClassification {
        let lowered = command.lowercased()

        // Shell-level constructs that are dangerous regardless of which segment
        // they appear in (pipe-to-shell, fork bomb, sensitive redirect targets,
        // AppleScript `do shell script` escape hatch).
        for (needle, reason) in highRiskSubstrings where lowered.contains(needle) {
            return ShellCommandClassification(tier: .highRisk, signature: needle.trimmingCharacters(in: .whitespaces), reason: reason)
        }

        // A redirect into a real device file (e.g. `> /dev/disk0`) can destroy a disk, but the benign
        // pseudo-device redirects — `2>/dev/null`, `>/dev/stdout`, `>/dev/fd/3` — are the single most
        // common reason a read-only probe looks dangerous, so they must NOT escalate. A blunt `>/dev`
        // substring caught both; this distinguishes the device name.
        if redirectsToRealDevice(lowered) {
            return ShellCommandClassification(tier: .highRisk, signature: "> /dev", reason: "writes to a device file")
        }

        // Split into command segments on shell separators and substitution
        // boundaries, then classify each segment's effective executable. The
        // overall tier is the most restrictive segment; the signature/reason
        // come from the first segment that reached that tier.
        var worst: ShellCommandClassification?
        for rawSegment in splitSegments(command) {
            let tokens = tokenize(rawSegment)
            guard !tokens.isEmpty else { continue }
            let classified = classifySegment(tokens)
            if worst == nil || classified.tier > worst!.tier {
                worst = classified
            }
        }

        // Empty/whitespace command: nothing to run, treat as a no-op read.
        return worst ?? ShellCommandClassification(tier: .read, signature: "", reason: nil)
    }

    // MARK: - Segment classification

    /// Classify one already-tokenized segment by its effective executable and
    /// subcommand. Wrapper commands (xargs/env/time/...) are unwrapped to the
    /// command they invoke so `xargs rm` is judged on `rm`.
    private static func classifySegment(_ tokens: [String]) -> ShellCommandClassification {
        var tokens = tokens
        var executable = normalizedExecutable(tokens.removeFirst())

        // `command -v X` / `command -V X` only test whether X exists; they never run it, so judge them
        // as reads instead of unwrapping `command` to the (often unrecognized) inner tool and prompting.
        if executable == "command", let first = tokens.first?.lowercased(), first == "-v" || first == "-V".lowercased() {
            return ShellCommandClassification(tier: .read, signature: "command -v", reason: nil)
        }

        // Unwrap argument-runner wrappers to the real command they execute.
        var unwrapGuard = 0
        while wrapperExecutables.contains(executable), unwrapGuard < 4 {
            // Skip wrapper flags/assignments (e.g. `env FOO=bar cmd`, `xargs -n1 cmd`).
            while let next = tokens.first, next.hasPrefix("-") || next.contains("=") {
                tokens.removeFirst()
            }
            guard !tokens.isEmpty else { break }
            executable = normalizedExecutable(tokens.removeFirst())
            unwrapGuard += 1
        }

        let firstArg = tokens.first.map { $0.lowercased() }

        // A command-execution flag runs an arbitrary command the same way `| sh` does, and it can ride
        // inside an otherwise-trusted tool — find's `-exec`, yt-dlp's `--exec`/`--exec-before-download`.
        // Gate it high-risk wherever it appears, BEFORE the read/bundled-tool classifications below, so the
        // escape hatch is never run silently no matter which executable carries it.
        if tokens.contains(where: isCommandExecutionFlag) {
            return ShellCommandClassification(tier: .highRisk, signature: "\(executable) -exec", reason: "runs an arbitrary command")
        }

        if let reason = highRiskExecutables[executable] {
            return ShellCommandClassification(tier: .highRisk, signature: executable, reason: reason)
        }

        // Tools Donkey ships in its own bundled-tools directory (first on PATH) are a first-party
        // capability surface — the media and document skills run them by bare name, the same way Donkey's
        // built-in file tools write files. They run immediately instead of being mis-scored as an
        // unrecognized "write" and gated on every clip or conversion. The escape-hatch flags that would
        // make one dangerous are already gated above; a dangerous wrapper (`yt-dlp … | sh`, a device
        // redirect) is caught by the whole-command checks in `classify` before any segment reaches here.
        if BundledTools.executableNames.contains(executable) {
            return ShellCommandClassification(tier: .read, signature: executable, reason: nil)
        }

        // Per-tool subcommand/flag refinement (read vs write of the same tool).
        if let refined = refine(executable: executable, tokens: tokens, firstArg: firstArg) {
            return refined
        }

        if readExecutables.contains(executable) {
            return ShellCommandClassification(tier: .read, signature: executable, reason: nil)
        }
        if let reason = reversibleWriteExecutables[executable] {
            return ShellCommandClassification(tier: .reversibleWrite, signature: executable, reason: reason)
        }

        // Unknown executable: don't auto-run and don't block — prompt once.
        return ShellCommandClassification(tier: .reversibleWrite, signature: executable, reason: "unrecognized command")
    }

    /// Tool-specific refinement: the same executable can be a read or a write
    /// depending on its subcommand or flags.
    private static func refine(executable: String, tokens: [String], firstArg: String?) -> ShellCommandClassification? {
        switch executable {
        case "defaults":
            switch firstArg {
            case "read", "read-type", "domains", "find", "export":
                return ShellCommandClassification(tier: .read, signature: "defaults read", reason: nil)
            case "delete":
                return ShellCommandClassification(tier: .highRisk, signature: "defaults delete", reason: "removes preference keys")
            case "write", "rename", "import":
                let sig = "defaults \(firstArg ?? "write")"
                if referencesSensitiveDomain(tokens) {
                    return ShellCommandClassification(tier: .highRisk, signature: sig, reason: "changes a security/privacy setting")
                }
                return ShellCommandClassification(tier: .reversibleWrite, signature: sig, reason: "changes an app preference")
            default:
                return ShellCommandClassification(tier: .reversibleWrite, signature: "defaults", reason: "changes a preference")
            }
        case "pmset":
            // `-g`/`-G` are read-only queries (battery, assertions, etc.).
            if tokens.contains("-g") || tokens.contains("-G") {
                return ShellCommandClassification(tier: .read, signature: "pmset -g", reason: nil)
            }
            return ShellCommandClassification(tier: .reversibleWrite, signature: "pmset", reason: "changes power settings")
        case "networksetup":
            if let firstArg, firstArg.hasPrefix("-get") || firstArg.hasPrefix("-list") {
                return ShellCommandClassification(tier: .read, signature: "networksetup \(firstArg)", reason: nil)
            }
            if let firstArg, firstArg.hasPrefix("-set") {
                return ShellCommandClassification(tier: .reversibleWrite, signature: "networksetup \(firstArg)", reason: "changes a network setting")
            }
            return ShellCommandClassification(tier: .reversibleWrite, signature: "networksetup", reason: "changes a network setting")
        case "scutil":
            // `scutil --get`/`scutil` queries are read; `--set` mutates.
            if tokens.contains("--set") {
                return ShellCommandClassification(tier: .reversibleWrite, signature: "scutil --set", reason: "changes a system identity setting")
            }
            return ShellCommandClassification(tier: .read, signature: "scutil", reason: nil)
        case "plutil":
            if tokens.contains("-convert") || tokens.contains("-replace") || tokens.contains("-insert") || tokens.contains("-remove") {
                return ShellCommandClassification(tier: .reversibleWrite, signature: "plutil", reason: "rewrites a plist")
            }
            return ShellCommandClassification(tier: .read, signature: "plutil -p", reason: nil)
        case "sed":
            if tokens.contains(where: { $0 == "-i" || $0.hasPrefix("-i") }) {
                return ShellCommandClassification(tier: .reversibleWrite, signature: "sed -i", reason: "edits a file in place")
            }
            return ShellCommandClassification(tier: .read, signature: "sed", reason: nil)
        default:
            return nil
        }
    }

    // MARK: - Tokenization

    /// Split a command into segments on shell separators (`;`, `|`, `&`, newline,
    /// backtick) and subshell/substitution opens (`(`), but ONLY when the separator
    /// is outside single/double quotes. A separator inside quotes is a literal part
    /// of an argument — e.g. the `|` in `grep -iE 'a|b'` or the `(` in a quoted glob
    /// pattern — and must not start a new "command" segment, or a read-only pipeline
    /// would be mis-scored as an unrecognized write and gated needlessly.
    static func splitSegments(_ command: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var escaped = false
        let chars = Array(command)
        for (idx, character) in chars.enumerated() {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\", !inSingle {
                current.append(character)
                escaped = true
                continue
            }
            if character == "'", !inDouble {
                inSingle.toggle()
                current.append(character)
                continue
            }
            if character == "\"", !inSingle {
                inDouble.toggle()
                current.append(character)
                continue
            }
            if !inSingle, !inDouble {
                // `&` is redirect syntax, not a separator, when it is part of `>&` (e.g. `2>&1`, `>&2`)
                // or `&>` (redirect both streams). Splitting there would peel the `1` off `2>&1` into a
                // bogus command segment and gate a read-only command needlessly.
                if character == "&" {
                    let prevIsRedirect = current.last == ">"
                    let nextIsRedirect = idx + 1 < chars.count && chars[idx + 1] == ">"
                    if prevIsRedirect || nextIsRedirect {
                        current.append(character)
                        continue
                    }
                }
                if ";|&\n`(".contains(character) {
                    segments.append(current)
                    current = ""
                    continue
                }
            }
            current.append(character)
        }
        segments.append(current)
        return segments
    }

    /// Split a segment into whitespace-separated tokens. Leading environment
    /// assignments (e.g. `FOO=bar cmd`) are dropped so the executable is found.
    private static func tokenize(_ segment: String) -> [String] {
        var tokens = segment
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        while let first = tokens.first, first.contains("="), !first.hasPrefix("-"), isLeadingAssignment(first) {
            tokens.removeFirst()
        }
        return tokens
    }

    private static func isLeadingAssignment(_ token: String) -> Bool {
        // NAME=VALUE with a valid env-var name on the left.
        guard let eq = token.firstIndex(of: "=") else { return false }
        let name = token[token.startIndex..<eq]
        return !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            && (name.first?.isNumber == false)
    }

    /// Path-strip and dequote a token down to its bare executable name.
    private static func normalizedExecutable(_ token: String) -> String {
        let dequoted = token.trimmingCharacters(in: CharacterSet(charactersIn: "\\'\"$"))
        let lastPathComponent = dequoted.split(separator: "/").last.map(String.init) ?? dequoted
        return lastPathComponent.lowercased()
    }

    private static func referencesSensitiveDomain(_ tokens: [String]) -> Bool {
        let joined = tokens.joined(separator: " ").lowercased()
        return sensitiveDomainNeedles.contains { joined.contains($0) }
    }

    /// True if the command redirects output into a real device file under `/dev` (e.g. `> /dev/disk0`,
    /// `>> /dev/rdisk1`). A redirect is `/dev/` immediately preceded by `>` (after optional whitespace and
    /// an fd number like the `2` in `2>`). The well-known pseudo-devices are writable harmlessly and are
    /// excluded so the ubiquitous `2>/dev/null` idiom on a read-only command stays read-only.
    private static func redirectsToRealDevice(_ lowered: String) -> Bool {
        let safeDevices: Set<String> = [
            "null", "zero", "stdout", "stderr", "stdin", "tty", "console", "random", "urandom", "fd"
        ]
        let chars = Array(lowered)
        let marker = Array("/dev/")
        var i = 0
        while i + marker.count <= chars.count {
            guard Array(chars[i ..< i + marker.count]) == marker else {
                i += 1
                continue
            }
            // Scan back past whitespace; the char before the target must be a redirect `>`.
            var j = i - 1
            while j >= 0, chars[j] == " " || chars[j] == "\t" { j -= 1 }
            if j >= 0, chars[j] == ">" {
                var k = i + marker.count
                var name = ""
                while k < chars.count, chars[k].isLetter || chars[k].isNumber || chars[k] == "_" {
                    name.append(chars[k])
                    k += 1
                }
                if !safeDevices.contains(name) {
                    return true
                }
            }
            i += marker.count
        }
        return false
    }

    // MARK: - Tables

    /// Commands that run another command passed as arguments; classification
    /// unwraps to that inner command.
    private static let wrapperExecutables: Set<String> = [
        "xargs", "env", "time", "nice", "nohup", "command", "builtin", "stdbuf", "timeout", "caffeinate"
    ]

    /// Flags that make a tool run an arbitrary command — `| sh` smuggled into an argument. Gated
    /// high-risk wherever they appear, so neither a trusted bundled tool nor a read-tier tool (find)
    /// can silently spawn a subcommand through them.
    private static let commandExecutionFlags: Set<String> = [
        "-exec", "-execdir", "--exec", "--exec-before-download"
    ]

    /// True when a token is a command-execution flag, including its `--exec=CMD` and `--exec-…` variants.
    private static func isCommandExecutionFlag(_ token: String) -> Bool {
        let lower = token.lowercased()
        return commandExecutionFlags.contains(lower) || lower.hasPrefix("--exec=") || lower.hasPrefix("--exec-")
    }

    /// Read-only inspection tools — safe to run without a prompt. Tools whose
    /// read/write split depends on a subcommand (defaults, pmset, networksetup,
    /// scutil, plutil, sed) are handled in `refine` and intentionally absent here.
    private static let readExecutables: Set<String> = [
        "ls", "cat", "head", "tail", "grep", "egrep", "fgrep", "rg", "find", "mdfind", "mdls",
        "which", "type", "whereis", "echo", "printf", "date", "cal", "df", "du", "pwd", "whoami",
        "id", "uname", "hostname", "sw_vers", "system_profiler", "ioreg", "vm_stat", "uptime",
        "stat", "file", "wc", "sort", "uniq", "cut", "tr", "awk", "basename", "dirname", "realpath",
        "pbpaste", "pgrep", "ps", "top", "lsof", "networkquality", "sysctl", "json_pp",
        "jq", "true", "false", "test", "seq", "md5", "shasum", "base64", "xxd", "od",
        "host", "dig", "arp", "ifconfig", "route", "last", "w", "finger", "groups"
    ]

    /// Reversible state changes — prompt once, eligible for "always allow".
    private static let reversibleWriteExecutables: [String: String] = [
        "open": "opens a file or app",
        "osascript": "runs an automation script",
        "killall": "quits an app by name",
        "pbcopy": "writes to the clipboard",
        "sips": "edits or converts an image",
        "mkdir": "creates a directory",
        "touch": "creates or updates a file",
        "ln": "creates a link",
        "cp": "copies a file",
        "mv": "moves or renames a file",
        "caffeinate": "keeps the Mac awake",
        "say": "speaks text aloud",
        "tee": "writes output to a file",
        "screencapture": "captures the screen to a file",
        "afplay": "plays an audio file"
    ]

    /// Destructive / privileged / network-egress — prompt every time, never
    /// eligible for "always allow". Value is the reason shown in the prompt.
    private static let highRiskExecutables: [String: String] = [
        "sudo": "runs with elevated privileges",
        "su": "switches user",
        "doas": "runs with elevated privileges",
        "rm": "deletes files",
        "rmdir": "deletes directories",
        "dd": "writes raw disk data",
        "mkfs": "formats a filesystem",
        "newfs_hfs": "formats a filesystem",
        "fdisk": "edits disk partitions",
        "gpt": "edits disk partitions",
        "diskutil": "modifies disks or volumes",
        "shred": "irreversibly wipes files",
        "srm": "irreversibly wipes files",
        "chmod": "changes file permissions",
        "chown": "changes file ownership",
        "chflags": "changes file flags",
        "shutdown": "shuts down the Mac",
        "reboot": "restarts the Mac",
        "halt": "halts the Mac",
        "kill": "sends a signal to a process",
        "pkill": "kills processes by pattern",
        "launchctl": "changes system services",
        "csrutil": "changes System Integrity Protection",
        "spctl": "changes security assessment policy",
        "nvram": "changes firmware variables",
        "fdesetup": "changes FileVault",
        "security": "accesses the keychain",
        "scp": "transfers files over the network",
        "sftp": "transfers files over the network",
        "ssh": "opens a remote shell",
        "telnet": "opens a remote connection",
        "nc": "opens a raw network connection",
        "ncat": "opens a raw network connection",
        "curl": "transfers data over the network",
        "wget": "downloads from the network",
        "eval": "evaluates a constructed command",
        "source": "sources a script into the shell"
    ]

    /// Whole-command shell constructs that are high-risk wherever they appear.
    private static let highRiskSubstrings: [(String, String)] = [
        ("| sh", "pipes output into a shell"),
        ("|sh", "pipes output into a shell"),
        ("| bash", "pipes output into a shell"),
        ("|bash", "pipes output into a shell"),
        ("| zsh", "pipes output into a shell"),
        ("|zsh", "pipes output into a shell"),
        (":(){", "fork bomb"),
        ("do shell script", "AppleScript shell escape"),
        ("> /system", "writes under /System"),
        (">/system", "writes under /System"),
        ("> /usr", "writes under /usr"),
        (">/usr", "writes under /usr"),
        ("> /etc", "writes under /etc"),
        (">/etc", "writes under /etc")
    ]

    /// Preference domains / phrases that make a `defaults`/settings write
    /// security- or privacy-sensitive (kept high-risk, no "always allow").
    private static let sensitiveDomainNeedles: [String] = [
        "com.apple.tcc", "com.apple.access", "com.apple.screensaver.askforpassword",
        "filevault", "fdesetup", "com.apple.security", "com.apple.loginwindow",
        "password", "com.apple.applicationaccess", "com.apple.mobiledevice"
    ]
}
