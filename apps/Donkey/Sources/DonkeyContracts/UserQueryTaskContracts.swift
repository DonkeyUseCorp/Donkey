import Foundation

public enum UserQueryTaskStatus: String, Codable, Equatable, Sendable {
    case chatting
    case running
    case paused
    case completed
    case waitingForClarification
    case waitingForPermission
    case waitingForReview
    case interrupted
    case needsAttention
    case failed
    case timedOut
}

public extension UserQueryTaskStatus {
    /// The agent is blocked asking the user to respond (a clarification or a review). These are the only
    /// states that surface a dedicated Reply button, since only here is the agent actively asking. Every
    /// state is repliable by tapping the row (a running/permission-gated thread takes the reply as a
    /// queued follow-up, the rest resume), so there is no separate "repliable" predicate — only this.
    var isAwaitingUserResponse: Bool {
        self == .waitingForClarification || self == .waitingForReview
    }
}

public struct UserQueryNotchTask: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var commandText: String
    public var status: UserQueryTaskStatus
    public var accentIndex: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var metadata: [String: String]

    public init(
        id: String,
        title: String,
        detail: String,
        commandText: String = "",
        status: UserQueryTaskStatus,
        accentIndex: Int,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.commandText = commandText
        self.status = status
        self.accentIndex = accentIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadata = metadata
    }
}

public extension UserQueryNotchTask {
    /// Metadata flag set while the assistant's final reply is streaming in token-by-token, so the chin
    /// switches from echoing the prompt to showing the growing answer even though the task is still
    /// running. Cleared implicitly once the task reaches a terminal status (which shows `detail` anyway).
    static let streamingAnswerMetadataKey = "notch.streamingAnswer"

    /// The single line the collapsed chin shows for this task: the user's prompt while it runs, the
    /// assistant's reply as it streams in (and once answered, its `detail`). The chin renderer and the
    /// chin-band height measurement both read this, so the band is always sized to the exact line it
    /// renders — a running task can't show a wrapped prompt inside a band measured for a shorter seed.
    var chinDisplayText: String {
        if status == .running {
            // Once the reply starts streaming, show the growing answer instead of the prompt.
            if metadata[Self.streamingAnswerMetadataKey] == "true",
               !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return detail
            }
            let prompt = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prompt.isEmpty { return prompt }
        }
        return detail.isEmpty ? title : detail
    }
}

public enum UserQueryTaskEventRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
    case system
    case tool
}

public struct UserQueryTaskEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var taskID: String
    public var role: UserQueryTaskEventRole
    public var text: String
    public var sequence: Int
    public var createdAt: Date

    public init(
        id: String,
        taskID: String,
        role: UserQueryTaskEventRole,
        text: String,
        sequence: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.role = role
        self.text = text
        self.sequence = sequence
        self.createdAt = createdAt
    }
}

public enum UserQueryTaskAssetSource: String, Codable, Equatable, Sendable {
    case userUploaded
    case agentReturned
}

public struct UserQueryTaskAsset: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var taskID: String
    public var eventID: String?
    public var source: UserQueryTaskAssetSource
    public var displayName: String
    public var contentType: String
    public var urlString: String
    public var byteCount: Int64?
    public var createdAt: Date

    public init(
        id: String,
        taskID: String,
        eventID: String? = nil,
        source: UserQueryTaskAssetSource,
        displayName: String,
        contentType: String,
        urlString: String,
        byteCount: Int64? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.eventID = eventID
        self.source = source
        self.displayName = displayName
        self.contentType = contentType
        self.urlString = urlString
        self.byteCount = byteCount
        self.createdAt = createdAt
    }
}

public struct UserQueryTaskAssetDraft: Codable, Equatable, Sendable {
    public var source: UserQueryTaskAssetSource
    public var displayName: String
    public var contentType: String
    public var urlString: String
    public var byteCount: Int64?

    public init(
        source: UserQueryTaskAssetSource = .userUploaded,
        displayName: String,
        contentType: String,
        urlString: String,
        byteCount: Int64? = nil
    ) {
        self.source = source
        self.displayName = displayName
        self.contentType = contentType
        self.urlString = urlString
        self.byteCount = byteCount
    }
}
