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

        // Split into command segments on shell separators and substitution
        // boundaries, then classify each segment's effective executable. The
        // overall tier is the most restrictive segment; the signature/reason
        // come from the first segment that reached that tier.
        var worst: ShellCommandClassification?
        let separators = CharacterSet(charactersIn: ";|&\n`(")
        for rawSegment in command.components(separatedBy: separators) {
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

        if let reason = highRiskExecutables[executable] {
            return ShellCommandClassification(tier: .highRisk, signature: executable, reason: reason)
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

    // MARK: - Tables

    /// Commands that run another command passed as arguments; classification
    /// unwraps to that inner command.
    private static let wrapperExecutables: Set<String> = [
        "xargs", "env", "time", "nice", "nohup", "command", "builtin", "stdbuf", "timeout", "caffeinate"
    ]

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
        ("> /dev", "writes to a device file"),
        (">/dev", "writes to a device file"),
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
