import Foundation

/// The canonical, human-readable record of a thread — the real conversation, the way ChatGPT or
/// Claude keeps one, not a debug dump. The user's request, session events, and the assistant's
/// answer are flat entries; each executed step is one grouped block (the decision — narration, thought,
/// action with its input — then that action's output), so the whole reasoning trace reads
/// decision → output → next decision.
///
/// Durable metadata stays in Core Data; the *contents* live here in markdown, one folder per thread
/// under `~/Library/Application Support/Donkey/Threads/<id>/`:
///
/// - `thread.md` — the full conversation, appended live (`tail -f` to watch it unfold).
/// - `summary.md` — a compacted, structured summary of the thread.
public final class ThreadTranscript: @unchecked Sendable {
    /// Who a flat entry is from.
    public enum Role: String, Sendable {
        case user
        case assistant
        case system
    }

    /// What kind of flat (non-step) entry it is. Executed steps render through `step(...)` instead.
    public enum Kind: String, Sendable {
        case message       // a plain user/system message
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

    /// The turn's upfront planning — the parsed understanding that anchors the run: the restated
    /// goal, the target app, the extracted parameters, the success criteria, and any clarification
    /// it decided to ask. Rendered as its own block at the start of every turn, so it appears at the
    /// beginning of the thread and again mid-thread when a clarification answer or permission grant
    /// opens a follow-up turn. Empty fields are omitted rather than printed as blank labels.
    public func planning(
        goal: String,
        targetApp: String? = nil,
        parameters: [String: String] = [:],
        successCriteria: String? = nil,
        clarification: String? = nil
    ) {
        var block = "\n### 🗺️ assistant · planning  \(Self.shortStamp(Date()))\n"
        block += "\n**Goal:** \(Self.clip(goal, 600))\n"
        if let targetApp = targetApp?.trimmingCharacters(in: .whitespacesAndNewlines), !targetApp.isEmpty {
            block += "\n**Target app:** \(targetApp)\n"
        }
        if !parameters.isEmpty {
            block += "\n**Parameters:**\n"
            for (key, value) in parameters.sorted(by: { $0.key < $1.key }) {
                block += "- \(key): \(Self.clip(value, 600))\n"
            }
        }
        if let criteria = successCriteria?.trimmingCharacters(in: .whitespacesAndNewlines), !criteria.isEmpty {
            block += "\n**Success criteria:** \(Self.clip(criteria, 600))\n"
        }
        if let clarification = clarification?.trimmingCharacters(in: .whitespacesAndNewlines), !clarification.isEmpty {
            block += "\n**Clarification needed:** \(Self.clip(clarification, 600))\n"
        }
        write(block, append: true)
    }

    /// One executed step, rendered as a single grouped block so the trace reads decision → output →
    /// next decision. The decision carries the model's full thought summary (bounded so a verbose
    /// chain of thought can't bloat the file — it is persisted only here, never in the per-step
    /// planning prompt), its warm one-line narration, and the action with its complete input. Planning
    /// retries hit while choosing this step open the block, so a step that needed recovery reads as
    /// one unit instead of scattered entries. The thought is also where the model interprets the
    /// previous step's output, so each block's output is reasoned about at the top of the next.
    ///
    /// The optional timing line closes the block with where the step's time went: how long the
    /// model spent deciding vs. how long the tool took to run, which sensing modality the step used
    /// (Accessibility vs. AI vision), whether that sensing came from cache, and how many elements it
    /// saw. The trace manager fills these from real spans and the executed tool's own facts; all are
    /// omitted when unknown so a non-sensing step (shell, wait, respond) stays clean.
    public func step(
        number: Int,
        thought: String?,
        narration: String?,
        tool: String,
        input: [String: String],
        status: String,
        output: String,
        planningErrors: [String] = [],
        decisionMS: Double? = nil,
        toolMS: Double? = nil,
        modality: String? = nil,
        cacheHit: Bool? = nil,
        elementCount: Int? = nil
    ) {
        var block = "\n## Step \(number)  \(Self.shortStamp(Date()))\n"
        for planningError in planningErrors {
            let text = Self.clip(planningError, 2_000)
            if !text.isEmpty { block += "\n⚠️ \(text)\n" }
        }
        block += "\n### 🧠 Decision\n"
        // The warm, first-person narration leads the block — it's the line the user reads as the agent's
        // own account of this step — with the fuller thought summary kept beneath it for the record.
        if let narration = narration?.trimmingCharacters(in: .whitespacesAndNewlines), !narration.isEmpty {
            block += "\n\(Self.clip(narration, 600))\n"
        }
        if let thought = thought?.trimmingCharacters(in: .whitespacesAndNewlines), !thought.isEmpty {
            block += "\n**Thought:** \(Self.clip(thought, 4_000))\n"
        }
        block += "\n**Action:** `\(tool)`\n```\n\(Self.inputBody(input))\n```\n"
        block += "\n### 📄 Output — `\(status)`\n\n```\n\(Self.clip(output, 2_000))\n```\n"
        if let timing = Self.timingLine(
            decisionMS: decisionMS,
            toolMS: toolMS,
            modality: modality,
            cacheHit: cacheHit,
            elementCount: elementCount
        ) {
            block += "\n\(timing)\n"
        }
        write(block, append: true)
    }

    /// One model call, recorded so every decision and every piece of data exchanged with the model is
    /// traceable in the thread: the clipped prompt that went out, the clipped reply that came back, the
    /// provider's finish reason, the attempt index for retried planning, the outcome, and the call's
    /// duration. The clip keeps a verbose prompt (full element list, tool descriptors, history) from
    /// bloating the file while still showing what was asked. The duration is how a slow turn is pinned
    /// to a specific call rather than a coarse end-to-end number.
    public func modelCall(
        kindLabel: String,
        prompt: String,
        response: String,
        finishReason: String? = nil,
        attempt: Int? = nil,
        durationMS: Double? = nil,
        status: String
    ) {
        var meta: [String] = []
        if let duration = Self.durationLabel(durationMS) { meta.append("**Duration:** \(duration)") }
        if let attempt { meta.append("**Attempt:** \(attempt)") }
        if let finishReason = finishReason?.trimmingCharacters(in: .whitespacesAndNewlines), !finishReason.isEmpty {
            meta.append("**Finish:** \(finishReason)")
        }
        meta.append("**Status:** \(status)")

        var block = "\n### 🔮 model · \(kindLabel)  \(Self.shortStamp(Date()))\n"
        block += "\n\(meta.joined(separator: "  ·  "))\n"
        block += "\n**Prompt:**\n```\n\(Self.clip(prompt, 3_000))\n```\n"
        block += "\n**Response:**\n```\n\(Self.clip(response, 2_000))\n```\n"
        write(block, append: true)
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
        case (.assistant, .response): return "💬"
        case (.system, .error): return "⚠️"
        case (.system, _): return "⚙️"
        default: return "•"
        }
    }

    private static func inputBody(_ input: [String: String]) -> String {
        input.isEmpty
            ? "(no input)"
            : input.sorted { $0.key < $1.key }
                .map { "\($0.key): \(clip($0.value, 600))" }
                .joined(separator: "\n")
    }

    /// The compact "where did the time go" line that closes a step block, e.g.
    /// `⏱ decision 8.4s · tool 0.3s · 👁️ vision · cache miss · 31 elems`. Returns nil when nothing is
    /// known, so a step with no timing or sensing prints no trailing line.
    private static func timingLine(
        decisionMS: Double?,
        toolMS: Double?,
        modality: String?,
        cacheHit: Bool?,
        elementCount: Int?
    ) -> String? {
        var segments: [String] = []
        if let decision = durationLabel(decisionMS) { segments.append("decision \(decision)") }
        if let tool = durationLabel(toolMS) { segments.append("tool \(tool)") }
        switch modality {
        case "accessibility": segments.append("🌲 AX")
        case "vision": segments.append("👁️ vision")
        default: break
        }
        if let cacheHit, modality != nil, modality != "none" {
            segments.append(cacheHit ? "cache hit" : "cache miss")
        }
        if let elementCount, modality != nil, modality != "none" {
            segments.append("\(elementCount) elems")
        }
        guard !segments.isEmpty else { return nil }
        return "<sub>⏱ \(segments.joined(separator: " · "))</sub>"
    }

    /// Human duration: `8.4s` for a second or more, `320ms` below that. nil for unknown/negative.
    private static func durationLabel(_ ms: Double?) -> String? {
        guard let ms, ms >= 0 else { return nil }
        return ms >= 1_000 ? String(format: "%.1fs", ms / 1_000) : String(format: "%.0fms", ms)
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
