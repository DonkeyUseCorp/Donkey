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
    /// (Ubiquitous system tools like `mdfind`/`defaults`/`open` are assumed, and the
    /// tools Donkey bundles — ffmpeg, yt-dlp, qpdf, exiftool, lit — are always present,
    /// so the skills assert them directly rather than probing.)
    private static let probedTools = [
        "gh", "git", "jq", "python3", "node", "brew", "rg", "swift", "docker", "go", "cargo",
        "pandoc", "magick", "sqlite3", "pdftotext", "mlr"
    ]

    private let cacheURL: URL
    private let ttl: TimeInterval
    private let toolNames: [String]
    private var cached: (expires: Date, summary: String)?
    private var probeTask: Task<Void, Never>?

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
    ///
    /// Never blocks on subprocesses: with no fresh cache it kicks the probe off
    /// in the background and returns an empty summary, so a user turn never
    /// waits on `which`/`--version` children. The next turn gets the cached line.
    public func summary(now: Date = Date()) async -> String {
        if let cached, cached.expires > now { return cached.summary }
        if let disk = loadFromDisk(), disk.expires > now {
            cached = disk
            return disk.summary
        }
        if probeTask == nil {
            let tools = toolNames
            probeTask = Task.detached(priority: .utility) { [weak self] in
                let summary = Self.probe(tools: tools)
                await self?.store(summary: summary)
            }
        }
        return ""
    }

    private func store(summary: String) {
        let entry = (expires: Date().addingTimeInterval(ttl), summary: summary)
        cached = entry
        saveToDisk(entry)
        probeTask = nil
    }

    // MARK: - Probing

    private static func probe(tools: [String]) -> String {
        var installed: [String] = []
        var missing: [String] = []
        for tool in tools {
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
    private static func version(of tool: String) -> String? {
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

    /// Run a short subprocess and return trimmed stdout (nil on failure). The
    /// bound is real: a wedged child is killed at the deadline, and stderr is
    /// drained concurrently so a chatty tool can't fill the pipe and deadlock.
    private static func run(
        _ launchPath: String,
        _ arguments: [String],
        timeout: TimeInterval = 3
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }

        DispatchQueue.global(qos: .utility).async {
            _ = errPipe.fileHandleForReading.readDataToEndOfFile()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1.0) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
            return nil
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
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
