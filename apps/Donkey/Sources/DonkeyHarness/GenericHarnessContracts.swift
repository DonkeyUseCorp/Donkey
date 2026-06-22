import DonkeyContracts
import Foundation

public enum HarnessStage: String, Codable, CaseIterable, Equatable, Sendable {
    case intake
    case intentAnalysis
    case contextGathering
    case worldModel
    case planning
    case execution
    case verification
    case recovery
    case clarification
    case permissionGate
    case lifecycle
}

public enum HarnessAgentStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case running
    case paused
    case waitingForUser
    case waitingForPermission
    case interrupted
    case resuming
    case completed
    case failedSafe
    case cancelled
    /// The run hit the runaway step ceiling (or a wall-clock limit) without completing. Terminal for
    /// the loop, but the goal still stands, so it surfaces as a retryable row rather than a failure.
    case timedOut

    public var canExecuteTools: Bool {
        self == .running || self == .resuming
    }
}

public enum HarnessAmbiguityClass: String, Codable, Equatable, Sendable {
    case safe
    case recoverable
    case dangerous
}

public enum HarnessRiskLevel: String, Codable, Equatable, Sendable {
    case low
    case medium
    case high
}

public enum HarnessPermission: String, Codable, CaseIterable, Hashable, Sendable {
    case conversation
    case memory
    case appLookup
    case appControl
    case screenCapture
    case accessibility
    case input
    case verification
    case lifecycle
    case userPrompt
    case skillLookup
}

public enum HarnessToolSafetyClass: String, Codable, Equatable, Sendable {
    case readOnly
    case reversible
    case guardedInput
    case destructive
    case sensitive
}

public enum HarnessToolResultStatus: String, Codable, Equatable, Sendable {
    case succeeded
    case failed
    case unknownTool
    case invalidInput
    case permissionDenied
    case waitingForUser
    case waitingForPermission
}

public struct HarnessIntentAnalysis: Codable, Equatable, Sendable {
    public var goal: String
    public var entities: [String: String]
    public var ambiguityClass: HarnessAmbiguityClass
    public var riskLevel: HarnessRiskLevel
    public var missingInformation: [String]
    public var shouldAskBeforeActing: Bool
    public var confidence: Double
    public var metadata: [String: String]

    public init(
        goal: String,
        entities: [String: String] = [:],
        ambiguityClass: HarnessAmbiguityClass = .recoverable,
        riskLevel: HarnessRiskLevel = .medium,
        missingInformation: [String] = [],
        shouldAskBeforeActing: Bool = false,
        confidence: Double = 0,
        metadata: [String: String] = [:]
    ) {
        self.goal = goal
        self.entities = entities
        self.ambiguityClass = ambiguityClass
        self.riskLevel = riskLevel
        self.missingInformation = missingInformation
        self.shouldAskBeforeActing = shouldAskBeforeActing
        self.confidence = min(max(confidence, 0), 1)
        self.metadata = metadata
    }
}

public struct HarnessContextSnapshot: Codable, Equatable, Sendable {
    public var turn: AppHarnessTurn?
    public var conversationID: String?
    public var memory: [String]
    public var availableToolNames: [String]
    public var availableSkillIDs: [String]
    public var policy: [String: String]
    public var metadata: [String: String]

    public init(
        turn: AppHarnessTurn? = nil,
        conversationID: String? = nil,
        memory: [String] = [],
        availableToolNames: [String] = [],
        availableSkillIDs: [String] = [],
        policy: [String: String] = [:],
        metadata: [String: String] = [:]
    ) {
        self.turn = turn
        self.conversationID = conversationID
        self.memory = memory
        self.availableToolNames = availableToolNames
        self.availableSkillIDs = availableSkillIDs
        self.policy = policy
        self.metadata = metadata
    }
}

public struct HarnessWorldModel: Codable, Equatable, Sendable {
    public var focusedApp: String?
    public var focusedWindowTitle: String?
    public var visibleText: [String: String]
    public var elements: [HarnessWorldElement]
    public var attemptedToolCalls: [HarnessToolCallRecord]
    public var facts: [String: String]
    public var uncertainty: [String]
    public var updatedAt: Date

    public init(
        focusedApp: String? = nil,
        focusedWindowTitle: String? = nil,
        visibleText: [String: String] = [:],
        elements: [HarnessWorldElement] = [],
        attemptedToolCalls: [HarnessToolCallRecord] = [],
        facts: [String: String] = [:],
        uncertainty: [String] = [],
        updatedAt: Date = Date()
    ) {
        self.focusedApp = focusedApp
        self.focusedWindowTitle = focusedWindowTitle
        self.visibleText = visibleText
        self.elements = elements
        self.attemptedToolCalls = attemptedToolCalls
        self.facts = facts
        self.uncertainty = uncertainty
        self.updatedAt = updatedAt
    }

    public func merging(result: HarnessToolResult) -> HarnessWorldModel {
        var model = self
        model.visibleText.merge(result.observations.visibleText) { _, new in new }
        model.facts.merge(result.observations.facts) { _, new in new }
        model.uncertainty = Array(Set(model.uncertainty + result.observations.uncertainty)).sorted()
        if !result.observations.elements.isEmpty {
            model.elements = result.observations.elements
        }
        if let focusedApp = result.observations.focusedApp {
            model.focusedApp = focusedApp
        }
        if let focusedWindowTitle = result.observations.focusedWindowTitle {
            model.focusedWindowTitle = focusedWindowTitle
        }
        model.updatedAt = result.completedAt
        return model
    }
}

public struct HarnessWorldElement: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var role: String
    public var isActionEligible: Bool
    public var actions: [String]
    public var metadata: [String: String]

    public init(
        id: String,
        label: String,
        role: String,
        isActionEligible: Bool,
        actions: [String] = [],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.label = label
        self.role = role
        self.isActionEligible = isActionEligible
        self.actions = actions
        self.metadata = metadata
    }
}

public struct HarnessPlan: Codable, Equatable, Sendable {
    public var goal: String
    public var steps: [HarnessPlanStep]
    public var successCriteria: [String]
    public var fallbackPolicy: [String]
    public var clarificationPolicy: [String]
    public var confidence: Double
    public var metadata: [String: String]

    public init(
        goal: String,
        steps: [HarnessPlanStep],
        successCriteria: [String] = [],
        fallbackPolicy: [String] = [],
        clarificationPolicy: [String] = [],
        confidence: Double = 0,
        metadata: [String: String] = [:]
    ) {
        self.goal = goal
        self.steps = steps
        self.successCriteria = successCriteria
        self.fallbackPolicy = fallbackPolicy
        self.clarificationPolicy = clarificationPolicy
        self.confidence = min(max(confidence, 0), 1)
        self.metadata = metadata
    }
}

public struct HarnessPlanStep: Codable, Equatable, Sendable {
    public var id: String
    public var summary: String
    public var toolCall: HarnessToolCall?
    public var expectedObservation: String?
    public var metadata: [String: String]

    public init(
        id: String,
        summary: String,
        toolCall: HarnessToolCall? = nil,
        expectedObservation: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.summary = summary
        self.toolCall = toolCall
        self.expectedObservation = expectedObservation
        self.metadata = metadata
    }
}

public struct HarnessToolCall: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var input: [String: String]
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        name: String,
        input: [String: String] = [:],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.input = input
        self.metadata = metadata
    }
}

public struct HarnessToolCallRecord: Codable, Equatable, Sendable {
    public var call: HarnessToolCall
    public var resultStatus: HarnessToolResultStatus
    public var summary: String
    public var recordedAt: Date

    public init(
        call: HarnessToolCall,
        resultStatus: HarnessToolResultStatus,
        summary: String,
        recordedAt: Date = Date()
    ) {
        self.call = call
        self.resultStatus = resultStatus
        self.summary = summary
        self.recordedAt = recordedAt
    }
}

public struct HarnessObservationDelta: Codable, Equatable, Sendable {
    public var focusedApp: String?
    public var focusedWindowTitle: String?
    public var visibleText: [String: String]
    public var elements: [HarnessWorldElement]
    public var facts: [String: String]
    public var uncertainty: [String]

    public init(
        focusedApp: String? = nil,
        focusedWindowTitle: String? = nil,
        visibleText: [String: String] = [:],
        elements: [HarnessWorldElement] = [],
        facts: [String: String] = [:],
        uncertainty: [String] = []
    ) {
        self.focusedApp = focusedApp
        self.focusedWindowTitle = focusedWindowTitle
        self.visibleText = visibleText
        self.elements = elements
        self.facts = facts
        self.uncertainty = uncertainty
    }
}

public struct HarnessToolResult: Codable, Equatable, Sendable {
    public var callID: String
    public var toolName: String
    public var status: HarnessToolResultStatus
    public var summary: String
    public var observations: HarnessObservationDelta
    public var missingPermissions: [HarnessPermission]
    public var question: String?
    public var completedAt: Date
    public var metadata: [String: String]

    public init(
        callID: String,
        toolName: String,
        status: HarnessToolResultStatus,
        summary: String,
        observations: HarnessObservationDelta = HarnessObservationDelta(),
        missingPermissions: [HarnessPermission] = [],
        question: String? = nil,
        completedAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.callID = callID
        self.toolName = toolName
        self.status = status
        self.summary = summary
        self.observations = observations
        self.missingPermissions = missingPermissions
        self.question = question
        self.completedAt = completedAt
        self.metadata = metadata
    }
}
