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
    public var conversationID: String?
    public var isFollowUp: Bool
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        text: String,
        source: AppHarnessTurnSource,
        conversationID: String? = nil,
        isFollowUp: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.source = source
        self.conversationID = conversationID
        self.isFollowUp = isFollowUp
        self.createdAt = createdAt
    }
}
