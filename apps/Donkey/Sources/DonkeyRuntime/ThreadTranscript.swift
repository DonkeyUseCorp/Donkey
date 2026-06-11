import Foundation

/// The canonical, human-readable record of a thread — the real conversation, the way ChatGPT or
/// Claude keeps one, not a debug dump. Every turn is captured with who said it and what kind of
/// message it is (a user request, the assistant thinking, a tool call, a tool result, the assistant's
/// answer), so you can read the whole reasoning trace and, later, render it to the user.
///
/// Durable metadata stays in Core Data; the *contents* live here in markdown, one folder per thread
/// under `~/Library/Application Support/Donkey/Threads/<id>/`:
///
/// - `thread.md` — the full conversation, appended live (`tail -f` to watch it unfold).
/// - `summary.md` — a compacted, structured summary of the thread.
public final class ThreadTranscript: @unchecked Sendable {
    /// Who an entry is from.
    public enum Role: String, Sendable {
        case user
        case assistant
        case tool
        case system
    }

    /// What kind of message it is.
    public enum Kind: String, Sendable {
        case message       // a plain user/system message
        case thinking      // the assistant's reasoning for the next move
        case toolCall      // the assistant invoking a tool
        case toolResult    // a tool's output
        case response      // the assistant's answer to the user
        case event         // a session lifecycle event (understanding parsed, run finished, …)
        case error         // something the session hit that wasn't a tool result (planner retry, aborted start, …)
    }

    public let directory: URL
    private let threadURL: URL
    private let summaryURL: URL
    private let lock = NSLock()
    private let started = Date()

    public static func defaultRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Donkey", isDirectory: true)
            .appendingPathComponent("Threads", isDirectory: true)
    }

    public init(id: String, root: URL? = nil) {
        let base = (root ?? Self.defaultRoot()).appendingPathComponent(Self.slug(id), isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.directory = base
        self.threadURL = base.appendingPathComponent("thread.md")
        self.summaryURL = base.appendingPathComponent("summary.md")
    }

    public var threadPath: String { threadURL.path }

    /// Start the thread file with its header (only written once; later turns append).
    public func begin(id: String, app: String) {
        guard !FileManager.default.fileExists(atPath: threadURL.path) else { return }
        let header = """
        # Thread \(id)

        - **App:** \(app.isEmpty ? "(system tools / none)" : app)
        - **Started:** \(Self.stamp(started))

        """
        write(header, append: false)
    }

    /// A user request opens a turn.
    public func userMessage(_ text: String) {
        appendEntry(role: .user, kind: .message, title: nil, body: text, fenced: false)
    }

    /// The assistant's reasoning before a tool call — the model's thought summary when thinking is on,
    /// otherwise the one-line rationale. Bounded so a verbose chain of thought can't bloat the thread
    /// file; the full reasoning lives only here, never in the per-step planning prompt.
    public func thinking(_ text: String?) {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        appendEntry(role: .assistant, kind: .thinking, title: nil, body: Self.clip(text, 4_000), fenced: false)
    }

    /// The assistant invoking a tool, with its input.
    public func toolCall(tool: String, input: [String: String]) {
        let body = input.isEmpty
            ? "(no input)"
            : input.sorted { $0.key < $1.key }
                .map { "\($0.key): \(Self.clip($0.value, 600))" }
                .joined(separator: "\n")
        appendEntry(role: .assistant, kind: .toolCall, title: tool, body: body, fenced: true)
    }

    /// A tool's result.
    public func toolResult(tool: String, status: String, output: String) {
        appendEntry(role: .tool, kind: .toolResult, title: "\(tool) → \(status)", body: Self.clip(output, 2_000), fenced: true)
    }

    /// The assistant's answer to the user, closing a turn.
    public func response(_ text: String) {
        appendEntry(role: .assistant, kind: .response, title: nil, body: text, fenced: false)
    }

    /// A session lifecycle event. The thread file is the COMPLETE record of a session — not only the
    /// tool turns — so things like the parsed understanding and the run's final outcome land here too.
    public func systemEvent(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        appendEntry(role: .system, kind: .event, title: nil, body: Self.clip(text, 2_000), fenced: false)
    }

    /// An error the session hit outside a tool result — a planner reply that couldn't be used, a run
    /// that aborted before it started. These must be readable in the thread, not buried in logs.
    public func error(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        appendEntry(role: .system, kind: .error, title: nil, body: Self.clip(text, 2_000), fenced: false)
    }

    /// Persist the compacted thread summary (callers generate it).
    public func writeSummary(_ markdown: String) {
        lock.lock(); defer { lock.unlock() }
        try? markdown.write(to: summaryURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Rendering

    /// One labeled block: a heading with role + kind (+ optional title), then the body.
    private func appendEntry(role: Role, kind: Kind, title: String?, body: String, fenced: Bool) {
        let label = "\(Self.icon(role, kind)) \(role.rawValue) · \(kind.rawValue)"
        let heading = title.map { "\(label) · `\($0)`" } ?? label
        let rendered = fenced ? "```\n\(body)\n```" : body
        let block = "\n### \(heading)  \(Self.shortStamp(Date()))\n\n\(rendered)\n"
        write(block, append: true)
    }

    private func write(_ text: String, append: Bool) {
        lock.lock(); defer { lock.unlock() }
        if append, let handle = try? FileHandle(forWritingTo: threadURL) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: threadURL, atomically: true, encoding: .utf8)
        }
    }

    private static func icon(_ role: Role, _ kind: Kind) -> String {
        switch (role, kind) {
        case (.user, _): return "👤"
        case (.assistant, .thinking): return "🧠"
        case (.assistant, .toolCall): return "🔧"
        case (.assistant, .response): return "💬"
        case (.tool, _): return "📄"
        case (.system, .error): return "⚠️"
        case (.system, _): return "⚙️"
        default: return "•"
        }
    }

    private static func clip(_ text: String, _ max: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > max ? String(trimmed.prefix(max)) + " …[clipped]" : trimmed
    }

    private static func slug(_ value: String) -> String {
        let s = value.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(s).isEmpty ? "thread" : String(s)
    }

    private static func stamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    private static func shortStamp(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return "<sub>\(f.string(from: date))</sub>"
    }
}
