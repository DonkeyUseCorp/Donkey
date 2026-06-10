import Foundation

/// Probes which command-line tools are installed on *this* Mac (and their
/// versions), so the planner reaches only for tools that actually exist and can
/// adapt to version differences instead of guessing.
///
/// The probe is read-only (`which` + a version flag), runs at most once per TTL,
/// and caches its summary to disk next to the other harness state. The summary
/// is a compact line injected into the planner's ENVIRONMENT block.
public actor SystemToolCapabilityProbe {
    public static let shared = SystemToolCapabilityProbe()

    /// Curated tools an expert might reach for that are NOT guaranteed present.
    /// (Ubiquitous system tools like `mdfind`/`defaults`/`open` are assumed.)
    private static let probedTools = [
        "gh", "git", "jq", "python3", "node", "brew", "rg", "swift", "ffmpeg", "docker", "go", "cargo"
    ]

    private let cacheURL: URL
    private let ttl: TimeInterval
    private let toolNames: [String]
    private var cached: (expires: Date, summary: String)?

    public init(
        cacheURL: URL? = nil,
        ttl: TimeInterval = 24 * 60 * 60,
        toolNames: [String]? = nil
    ) {
        self.cacheURL = cacheURL ?? Self.defaultCacheURL()
        self.ttl = ttl
        self.toolNames = toolNames ?? Self.probedTools
    }

    private static func defaultCacheURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Donkey", isDirectory: true)
            .appendingPathComponent("HarnessStore", isDirectory: true)
            .appendingPathComponent("tool-capabilities.json")
    }

    /// A one-line summary of installed vs missing tools, e.g.
    /// `Installed: git 2.43, jq 1.7, python3 3.12.2. Not installed: node, ffmpeg.`
    /// Cached in memory and on disk; recomputed only after the TTL lapses.
    public func summary(now: Date = Date()) async -> String {
        if let cached, cached.expires > now { return cached.summary }
        if let disk = loadFromDisk(), disk.expires > now {
            cached = disk
            return disk.summary
        }
        let summary = probe()
        let entry = (expires: now.addingTimeInterval(ttl), summary: summary)
        cached = entry
        saveToDisk(entry)
        return summary
    }

    // MARK: - Probing

    private func probe() -> String {
        var installed: [String] = []
        var missing: [String] = []
        for tool in toolNames {
            guard let path = run("/usr/bin/which", [tool]), !path.isEmpty else {
                missing.append(tool)
                continue
            }
            if let version = version(of: tool) {
                installed.append("\(tool) \(version)")
            } else {
                installed.append(tool)
            }
        }
        var parts: [String] = []
        if !installed.isEmpty { parts.append("Installed: \(installed.joined(separator: ", ")).") }
        if !missing.isEmpty { parts.append("Not installed: \(missing.joined(separator: ", ")).") }
        return parts.joined(separator: " ")
    }

    /// Best-effort version string from the tool's own version flag.
    private func version(of tool: String) -> String? {
        guard let raw = run("/usr/bin/env", [tool, "--version"]) ?? run("/usr/bin/env", [tool, "version"]) else {
            return nil
        }
        let firstLine = raw.split(separator: "\n").first.map(String.init) ?? raw
        // Pull the first dotted numeric token (e.g. "git version 2.43.0" -> "2.43.0").
        for token in firstLine.split(whereSeparator: { $0 == " " || $0 == "," }) {
            let candidate = token.trimmingCharacters(in: CharacterSet(charactersIn: "v()"))
            if candidate.contains("."), candidate.first?.isNumber == true {
                return candidate
            }
        }
        return nil
    }

    /// Run a short, bounded subprocess and return trimmed stdout (nil on failure).
    private func run(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    // MARK: - Persistence

    private func loadFromDisk() -> (expires: Date, summary: String)? {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode(PersistedProbe.self, from: data) else {
            return nil
        }
        return (decoded.expires, decoded.summary)
    }

    private func saveToDisk(_ entry: (expires: Date, summary: String)) {
        let payload = PersistedProbe(expires: entry.expires, summary: entry.summary)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: cacheURL, options: .atomic)
    }

    private struct PersistedProbe: Codable {
        var expires: Date
        var summary: String
    }
}
