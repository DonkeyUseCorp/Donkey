import Foundation

public enum UserQueryConversationStatus: String, Codable, Equatable, Sendable {
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

public extension UserQueryConversationStatus {
    /// The agent is blocked asking the user to respond (a clarification or a review). These are the only
    /// states that surface a dedicated Reply button, since only here is the agent actively asking. Every
    /// state is repliable by tapping the row (a running/permission-gated thread takes the reply as a
    /// queued follow-up, the rest resume), so there is no separate "repliable" predicate — only this.
    var isAwaitingUserResponse: Bool {
        self == .waitingForClarification || self == .waitingForReview
    }
}

public struct UserQueryConversation: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var commandText: String
    public var status: UserQueryConversationStatus
    public var accentIndex: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var metadata: [String: String]

    public init(
        id: String,
        title: String,
        detail: String,
        commandText: String = "",
        status: UserQueryConversationStatus,
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

public extension UserQueryConversation {
    /// The single line the collapsed chin shows for this task: the user's prompt while it runs, the
    /// assistant's reply as it streams in (and once answered, its `detail`). The chin renderer and the
    /// chin-band height measurement both read this, so the band is always sized to the exact line it
    /// renders — a running task can't show a wrapped prompt inside a band measured for a shorter seed.
    var chinDisplayText: String {
        if status == .running {
            // While the agent works, the chin narrates its latest step — each planner narration and the
            // streaming final answer land in `detail`. Show that the moment it advances past the initial
            // "Thinking" seed; the user's prompt is only the first frame, before any narration arrives.
            let detailText = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !detailText.isEmpty, detailText != UserQueryActivity.Kind.working.label {
                return detail
            }
            let prompt = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prompt.isEmpty { return prompt }
        }
        return detail.isEmpty ? title : detail
    }
}

public enum UserQueryConversationEventRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
    case system
    case tool
}

public struct UserQueryConversationEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var conversationID: String
    public var role: UserQueryConversationEventRole
    public var text: String
    public var sequence: Int
    public var createdAt: Date

    public init(
        id: String,
        conversationID: String,
        role: UserQueryConversationEventRole,
        text: String,
        sequence: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.role = role
        self.text = text
        self.sequence = sequence
        self.createdAt = createdAt
    }
}

public enum UserQueryConversationAssetSource: String, Codable, Equatable, Sendable {
    case userUploaded
    case agentReturned
}

public struct UserQueryConversationAsset: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var conversationID: String
    public var eventID: String?
    public var source: UserQueryConversationAssetSource
    public var displayName: String
    public var contentType: String
    public var urlString: String
    public var byteCount: Int64?
    public var createdAt: Date

    public init(
        id: String,
        conversationID: String,
        eventID: String? = nil,
        source: UserQueryConversationAssetSource,
        displayName: String,
        contentType: String,
        urlString: String,
        byteCount: Int64? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.eventID = eventID
        self.source = source
        self.displayName = displayName
        self.contentType = contentType
        self.urlString = urlString
        self.byteCount = byteCount
        self.createdAt = createdAt
    }
}

public struct UserQueryConversationAssetDraft: Codable, Equatable, Sendable {
    public var source: UserQueryConversationAssetSource
    public var displayName: String
    public var contentType: String
    public var urlString: String
    public var byteCount: Int64?

    public init(
        source: UserQueryConversationAssetSource = .userUploaded,
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
