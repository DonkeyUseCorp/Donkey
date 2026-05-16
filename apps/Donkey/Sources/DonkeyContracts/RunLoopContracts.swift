import Foundation

public enum RunLifecycleState: String, Equatable, Sendable {
    case idle
    case starting
    case running
    case paused
    case stopping
    case completed
    case aborted
    case timedOut
    case failed

    public var isTerminal: Bool {
        switch self {
        case .completed, .aborted, .timedOut, .failed:
            return true
        case .idle, .starting, .running, .paused, .stopping:
            return false
        }
    }
}

public enum RunEventStream: String, Equatable, Sendable {
    case assistant
    case tool
    case lifecycle
    case reflex
}

public enum ToolCallCapability: String, CaseIterable, Equatable, Hashable, Sendable {
    case capture
    case accessibility
    case model
    case input
    case persistence
    case perception
    case controller
}

public enum ToolCallDecision: Equatable, Sendable {
    case allow
    case deny(reason: String)
    case ask(reason: String)

    public var isAllowed: Bool {
        self == .allow
    }
}

public struct ToolCallPolicy: Equatable, Sendable {
    public var allowedCapabilities: Set<ToolCallCapability>
    public var deniedCapabilities: Set<ToolCallCapability>
    public var approvalRequiredCapabilities: Set<ToolCallCapability>

    public init(
        allowedCapabilities: Set<ToolCallCapability> = ToolCallPolicy.defaultAllowedCapabilities,
        deniedCapabilities: Set<ToolCallCapability> = [.input],
        approvalRequiredCapabilities: Set<ToolCallCapability> = []
    ) {
        self.allowedCapabilities = allowedCapabilities
        self.deniedCapabilities = deniedCapabilities
        self.approvalRequiredCapabilities = approvalRequiredCapabilities
    }

    public func decision(for capability: ToolCallCapability) -> ToolCallDecision {
        if deniedCapabilities.contains(capability) {
            return .deny(reason: "\(capability.rawValue) capability is denied by policy")
        }

        if approvalRequiredCapabilities.contains(capability) {
            return .ask(reason: "\(capability.rawValue) capability requires approval")
        }

        if allowedCapabilities.contains(capability) {
            return .allow
        }

        return .deny(reason: "\(capability.rawValue) capability is not explicitly allowed")
    }

    public static let defaultAllowedCapabilities: Set<ToolCallCapability> = [
        .capture,
        .accessibility,
        .model,
        .persistence,
        .perception,
        .controller
    ]

    public static let `default` = ToolCallPolicy()
}

public struct RunSession: Equatable, Sendable {
    public var id: String
    public var userGoal: String
    public var targetID: String
    public var runtimeProfile: String
    public var permissionPolicy: ToolCallPolicy
    public var lifecycleState: RunLifecycleState

    public init(
        id: String = UUID().uuidString,
        userGoal: String,
        targetID: String,
        runtimeProfile: String = "default",
        permissionPolicy: ToolCallPolicy = .default,
        lifecycleState: RunLifecycleState = .idle
    ) {
        self.id = id
        self.userGoal = userGoal
        self.targetID = targetID
        self.runtimeProfile = runtimeProfile
        self.permissionPolicy = permissionPolicy
        self.lifecycleState = lifecycleState
    }
}

public struct AssistantRunEvent: Equatable, Sendable {
    public var message: String

    public init(message: String) {
        self.message = message
    }
}

public struct ToolRunEvent: Equatable, Sendable {
    public var capability: ToolCallCapability
    public var decision: ToolCallDecision
    public var toolName: String?

    public init(
        capability: ToolCallCapability,
        decision: ToolCallDecision,
        toolName: String? = nil
    ) {
        self.capability = capability
        self.decision = decision
        self.toolName = toolName
    }
}

public struct LifecycleRunEvent: Equatable, Sendable {
    public var state: RunLifecycleState
    public var reason: String?

    public init(state: RunLifecycleState, reason: String? = nil) {
        self.state = state
        self.reason = reason
    }
}

public struct ReflexRunEvent: Equatable, Sendable {
    public var frameID: String?
    public var stateID: String?
    public var actionID: String?
    public var sampled: Bool

    public init(
        frameID: String? = nil,
        stateID: String? = nil,
        actionID: String? = nil,
        sampled: Bool = true
    ) {
        self.frameID = frameID
        self.stateID = stateID
        self.actionID = actionID
        self.sampled = sampled
    }
}

public enum RunEventPayload: Equatable, Sendable {
    case assistant(AssistantRunEvent)
    case tool(ToolRunEvent)
    case lifecycle(LifecycleRunEvent)
    case reflex(ReflexRunEvent)
}

public struct RunEvent: Equatable, Sendable {
    public var sequence: Int
    public var stream: RunEventStream
    public var summary: String
    public var payload: RunEventPayload
    public var traceID: String?
    public var metadata: [String: String]
    public var requiresInputRelease: Bool

    public init(
        sequence: Int = 0,
        stream: RunEventStream,
        summary: String,
        payload: RunEventPayload,
        traceID: String? = nil,
        metadata: [String: String] = [:],
        requiresInputRelease: Bool = false
    ) {
        self.sequence = sequence
        self.stream = stream
        self.summary = summary
        self.payload = payload
        self.traceID = traceID
        self.metadata = metadata
        self.requiresInputRelease = requiresInputRelease
    }

    public func assigningSequence(_ sequence: Int) -> RunEvent {
        var copy = self
        copy.sequence = sequence
        return copy
    }
}

public struct RunWorldStateSummary: Equatable, Sendable {
    public var stateID: String
    public var summary: String
    public var confidence: Double

    public init(stateID: String, summary: String, confidence: Double) {
        self.stateID = stateID
        self.summary = summary
        self.confidence = confidence
    }
}

public struct RunPlannerHint: Equatable, Sendable {
    public var id: String
    public var summary: String
    public var isValid: Bool

    public init(id: String, summary: String, isValid: Bool = true) {
        self.id = id
        self.summary = summary
        self.isValid = isValid
    }
}

public struct RunFailureSummary: Equatable, Sendable {
    public var traceID: String
    public var summary: String

    public init(traceID: String, summary: String) {
        self.traceID = traceID
        self.summary = summary
    }
}

public struct RunContextPackage: Equatable, Sendable {
    public var sessionID: String
    public var userGoal: String
    public var targetID: String
    public var runtimeProfile: String
    public var latestWorldState: RunWorldStateSummary?
    public var transcriptSummary: String
    public var droppedTranscriptCharacterCount: Int
    public var activeHints: [RunPlannerHint]
    public var recentFailures: [RunFailureSummary]

    public init(
        sessionID: String,
        userGoal: String,
        targetID: String,
        runtimeProfile: String,
        latestWorldState: RunWorldStateSummary? = nil,
        transcriptSummary: String,
        droppedTranscriptCharacterCount: Int = 0,
        activeHints: [RunPlannerHint] = [],
        recentFailures: [RunFailureSummary] = []
    ) {
        self.sessionID = sessionID
        self.userGoal = userGoal
        self.targetID = targetID
        self.runtimeProfile = runtimeProfile
        self.latestWorldState = latestWorldState
        self.transcriptSummary = transcriptSummary
        self.droppedTranscriptCharacterCount = droppedTranscriptCharacterCount
        self.activeHints = activeHints
        self.recentFailures = recentFailures
    }
}
