import Foundation

public enum AppHarnessTurnSource: String, Codable, Equatable, Sendable {
    case typedPrompt
    case voiceTranscript
    case followUp
    case assetEvent
}

public enum AppHarnessTurnRouteKind: String, Codable, Equatable, Sendable {
    case conversation
    case clarification
    case actionableIntent
    case review
    case execution
    case failure
    case assistantResponse
    case noOp
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
    public var role: PointerPromptTaskEventRole
    public var text: String
    public var sequence: Int

    public init(role: PointerPromptTaskEventRole, text: String, sequence: Int) {
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
        self.metadata = metadata
    }
}
