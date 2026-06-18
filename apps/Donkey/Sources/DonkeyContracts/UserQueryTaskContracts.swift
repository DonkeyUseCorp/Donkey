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
