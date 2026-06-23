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

/// Who started a conversation. `user` is the default — anything the person typed, spoke, or resumed,
/// and which they own (stop, resume, reply, dismiss). `system` is started by the app itself (e.g. the
/// first-run download of the bundled CLI tools): the person watches its progress like any other
/// conversation, but it runs to completion under the app's control and is never user-stoppable or
/// -dismissable. The distinction is typed rather than inferred so the "can't touch it" rule holds by
/// construction everywhere — the row controls, the lifecycle methods, follow-up routing, and restore.
public enum UserQueryConversationOrigin: String, Codable, Equatable, Sendable {
    case user
    case system
}

public struct UserQueryConversation: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var commandText: String
    public var status: UserQueryConversationStatus
    public var accentIndex: Int
    public var origin: UserQueryConversationOrigin
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
        origin: UserQueryConversationOrigin = .user,
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
        self.origin = origin
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadata = metadata
    }
}

public extension UserQueryConversation {
    /// Whether the person may control this conversation — stop it, resume it, reply to it, or dismiss it.
    /// Only conversations they started are theirs to control; a system-driven one (tool setup) is watched,
    /// not operated. Every control surface and lifecycle hook gates on this, so the rule can't be missed.
    var isUserControllable: Bool { origin == .user }
}

public extension UserQueryConversation {
    /// The single line the collapsed chin shows for this task — always the latest line of the
    /// conversation. `detail` is the one field that carries it: the user's message the instant they send
    /// it, the agent's live step narration while it works, then the agent's reply. Each of those writes
    /// `detail` at its own source (see `UserQueryOverlayModel`), so the chin never reconstructs "what's
    /// newest" from the prompt, title, and status — it just renders this. `title` (the first prompt) is
    /// only a fallback for a task that has no line yet. The chin renderer and the chin-band height
    /// measurement both read this, so the band is always sized to the exact line it renders.
    var chinDisplayText: String {
        detail.isEmpty ? title : detail
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
