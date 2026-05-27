import Foundation

public enum AppHarnessTurnSource: String, Codable, Equatable, Sendable {
    case typedPrompt
    case voiceTranscript
    case followUp
    case assetEvent
}

public enum AppHarnessDecisionKind: String, Codable, Equatable, Sendable {
    case respond
    case askClarification
    case openReview
    case runLocalTask
    case noOp
}

public struct AppHarnessDecision: Codable, Equatable, Sendable {
    public var kind: AppHarnessDecisionKind
    public var message: String?
    public var missingDetail: String?
    public var taskIntentID: String?
    public var traceID: String
    public var metadata: [String: String]

    public init(
        kind: AppHarnessDecisionKind,
        message: String? = nil,
        missingDetail: String? = nil,
        taskIntentID: String? = nil,
        traceID: String,
        metadata: [String: String] = [:]
    ) {
        self.kind = kind
        self.message = message
        self.missingDetail = missingDetail
        self.taskIntentID = taskIntentID
        self.traceID = traceID
        self.metadata = metadata
    }
}

public enum AppHarnessContextItemKind: String, Codable, Equatable, Sendable {
    case currentTurn
    case recentEvent
    case transientCorrection
    case asset
    case memory
    case runtimeCapability
    case targetState
    case policy
}

public struct AppHarnessContextCompactionRecord: Codable, Equatable, Sendable {
    public var itemKind: AppHarnessContextItemKind
    public var originalCount: Int
    public var includedCount: Int
    public var droppedCount: Int
    public var truncatedCount: Int
    public var metadata: [String: String]

    public init(
        itemKind: AppHarnessContextItemKind,
        originalCount: Int,
        includedCount: Int,
        droppedCount: Int = 0,
        truncatedCount: Int = 0,
        metadata: [String: String] = [:]
    ) {
        self.itemKind = itemKind
        self.originalCount = max(0, originalCount)
        self.includedCount = max(0, includedCount)
        self.droppedCount = max(0, droppedCount)
        self.truncatedCount = max(0, truncatedCount)
        self.metadata = metadata
    }
}

public struct AppHarnessTurn: Codable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var source: AppHarnessTurnSource
    public var taskID: String?
    public var isFollowUp: Bool
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        text: String,
        source: AppHarnessTurnSource,
        taskID: String? = nil,
        isFollowUp: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.source = source
        self.taskID = taskID
        self.isFollowUp = isFollowUp
        self.createdAt = createdAt
    }
}

public struct AppHarnessContextEvent: Codable, Equatable, Sendable {
    public var role: UserQueryTaskEventRole
    public var text: String
    public var sequence: Int

    public init(role: UserQueryTaskEventRole, text: String, sequence: Int) {
        self.role = role
        self.text = text
        self.sequence = sequence
    }
}

public struct AppHarnessContextAsset: Codable, Equatable, Sendable {
    public var displayName: String
    public var contentType: String
    public var byteCount: Int64?

    public init(displayName: String, contentType: String, byteCount: Int64? = nil) {
        self.displayName = displayName
        self.contentType = contentType
        self.byteCount = byteCount
    }
}

public struct AppHarnessContextPacket: Codable, Equatable, Sendable {
    public var traceID: String
    public var currentTurn: AppHarnessTurn
    public var recentEvents: [AppHarnessContextEvent]
    public var assets: [AppHarnessContextAsset]
    public var runtimeCapabilities: [String]
    public var targetState: [String: String]
    public var memory: [String]
    public var policy: [String: String]
    public var promptText: String
    public var redactionCount: Int
    public var compactionRecords: [AppHarnessContextCompactionRecord]
    public var metadata: [String: String]

    public init(
        traceID: String,
        currentTurn: AppHarnessTurn,
        recentEvents: [AppHarnessContextEvent] = [],
        assets: [AppHarnessContextAsset] = [],
        runtimeCapabilities: [String] = [],
        targetState: [String: String] = [:],
        memory: [String] = [],
        policy: [String: String] = [:],
        promptText: String,
        redactionCount: Int = 0,
        compactionRecords: [AppHarnessContextCompactionRecord] = [],
        metadata: [String: String] = [:]
    ) {
        self.traceID = traceID
        self.currentTurn = currentTurn
        self.recentEvents = recentEvents
        self.assets = assets
        self.runtimeCapabilities = runtimeCapabilities
        self.targetState = targetState
        self.memory = memory
        self.policy = policy
        self.promptText = promptText
        self.redactionCount = redactionCount
        self.compactionRecords = compactionRecords
        self.metadata = metadata
    }
}
