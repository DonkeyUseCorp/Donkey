import Foundation

/// A typed, presentable unit of "what the agent is doing" inside a task.
///
/// This is the single, centralized vocabulary the UI speaks instead of scattering ad-hoc status
/// strings ("Approved — continuing", "Running", …) across the model and the views. It drives the
/// notch status line today and is built to back the full conversation/transcript view next: each
/// rendered line is one `UserQueryActivity`, so adding a row type later means adding a `Kind` case
/// and its presentation here — nothing else changes.
///
/// Classification only ever matches typed fields (task status, registry tool names), never raw user
/// text, per the harness rules.
public struct UserQueryActivity: Equatable, Sendable {
    /// The kinds of activity a task surfaces. Extend by adding a case plus its entry in `label`,
    /// `systemImage`, and `transcriptIcon` — those switches are exhaustive so the compiler flags any
    /// case left unpresented.
    public enum Kind: String, Codable, Equatable, Sendable, CaseIterable {
        case working          // generic in-progress / thinking
        case observing        // reading the screen (accessibility / vision)
        case reading          // reading a file or document
        case editing          // changing UI state (click, type, drag)
        case searching        // looking something up
        case running          // running a shell command / skill
        case browsing         // navigating the web or an app
        case verifying        // checking the result holds
        case message          // a conversational reply
        case waitingForInput  // needs the user to answer
        case waitingForPermission
        case waitingForReview
        case paused
        case resumed
        case completed
        case failed
        case interrupted
        case needsAttention
    }

    public var kind: Kind
    /// Free-text specifics (the model's narration, the consent reason, an error). Empty falls back to
    /// the kind's label.
    public var summary: String

    public init(kind: Kind, summary: String = "") {
        self.kind = kind
        self.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The user-facing one-liner: the activity's own text when it has any, else the kind's label.
    public var displayText: String {
        summary.isEmpty ? kind.label : summary
    }

    /// SF Symbol for in-app surfaces (the notch and the future conversation view).
    public var systemImage: String { kind.systemImage }

    /// The line written into the conversation record (`thread.md`), prefixed with the kind's icon so
    /// it reads on its own when the thread is rendered back to the user.
    public var transcriptLine: String {
        "\(kind.transcriptIcon) \(displayText)"
    }
}

public extension UserQueryActivity.Kind {
    /// The concise label shown when an activity has no specifics of its own.
    var label: String {
        switch self {
        case .working: return "Working"
        case .observing: return "Looking at the screen"
        case .reading: return "Reading"
        case .editing: return "Making changes"
        case .searching: return "Searching"
        case .running: return "Running a command"
        case .browsing: return "Browsing"
        case .verifying: return "Verifying"
        case .message: return "Conversation"
        case .waitingForInput: return "Waiting for your reply"
        case .waitingForPermission: return "Waiting for approval"
        case .waitingForReview: return "Waiting for your review"
        case .paused: return "Paused"
        case .resumed: return "Resuming"
        case .completed: return "Done"
        case .failed: return "Stopped"
        case .interrupted: return "Changed course"
        case .needsAttention: return "Needs attention"
        }
    }

    /// SF Symbol used by in-app surfaces.
    var systemImage: String {
        switch self {
        case .working: return "ellipsis"
        case .observing: return "eye"
        case .reading: return "doc.text"
        case .editing: return "pencil"
        case .searching: return "magnifyingglass"
        case .running: return "terminal"
        case .browsing: return "safari"
        case .verifying: return "checkmark.seal"
        case .message: return "text.bubble"
        case .waitingForInput: return "questionmark.circle"
        case .waitingForPermission: return "lock.shield"
        case .waitingForReview: return "doc.text.magnifyingglass"
        case .paused: return "pause.circle"
        case .resumed: return "play.circle"
        case .completed: return "checkmark.circle"
        case .failed: return "xmark.circle"
        case .interrupted: return "arrow.triangle.branch"
        case .needsAttention: return "exclamationmark.circle"
        }
    }

    /// Emoji used in the markdown conversation record (`thread.md`).
    var transcriptIcon: String {
        switch self {
        case .working: return "⚙️"
        case .observing: return "👀"
        case .reading: return "📄"
        case .editing: return "✏️"
        case .searching: return "🔍"
        case .running: return "⌨️"
        case .browsing: return "🧭"
        case .verifying: return "✅"
        case .message: return "💬"
        case .waitingForInput: return "❓"
        case .waitingForPermission: return "🔒"
        case .waitingForReview: return "📝"
        case .paused: return "⏸️"
        case .resumed: return "▶️"
        case .completed: return "🎉"
        case .failed: return "⚠️"
        case .interrupted: return "🔀"
        case .needsAttention: return "❗️"
        }
    }
}

public extension UserQueryActivity {
    /// Maps a task's lifecycle status to an activity kind.
    static func kind(forStatus status: UserQueryTaskStatus) -> Kind {
        switch status {
        case .chatting: return .message
        case .running: return .working
        case .paused: return .paused
        case .completed: return .completed
        case .waitingForClarification: return .waitingForInput
        case .waitingForPermission: return .waitingForPermission
        case .waitingForReview: return .waitingForReview
        case .interrupted: return .interrupted
        case .needsAttention: return .needsAttention
        case .failed: return .failed
        }
    }

    /// Classifies a running step by its registry tool name (a typed field, never user text). Unknown
    /// tools fall back to `.working`; add a case as new tool families surface in the conversation view.
    static func kind(forToolNamed name: String) -> Kind {
        let tool = name.lowercased()
        switch tool {
        case "shell_exec", "skill_run": return .running
        case "ax.observe", "vision.capture": return .observing
        case "conversation.respond": return .message
        case "user.clarify": return .waitingForInput
        case "permission.request": return .waitingForPermission
        case "run.complete": return .completed
        default: break
        }

        // Family heuristics on the typed tool name for tools not called out above.
        if tool.hasSuffix(".search") { return .searching }
        if tool.hasSuffix(".read") || tool.hasPrefix("file") { return .reading }
        if tool.hasSuffix(".verify") { return .verifying }
        if tool.contains(".click") || tool.contains(".type") || tool.contains(".press")
            || tool.contains(".drag") || tool.contains(".scroll") {
            return .editing
        }
        return .working
    }

    /// The activity a task is currently surfacing. While running it prefers the live tool hint
    /// (`activity.tool` metadata) so the line reads like the agent's current step; otherwise the
    /// status drives the kind. The task's `detail` carries any specifics.
    static func current(for task: UserQueryNotchTask) -> UserQueryActivity {
        let summary = task.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind: Kind
        if task.status == .running, let tool = task.metadata["activity.tool"], !tool.isEmpty {
            kind = self.kind(forToolNamed: tool)
        } else {
            kind = self.kind(forStatus: task.status)
        }
        return UserQueryActivity(kind: kind, summary: summary)
    }
}
