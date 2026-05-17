import Foundation

public enum TaskIntentParserSource: String, Codable, Equatable, Sendable {
    case deterministic
    case localModel = "local_model"
    case onlineModel = "online_model"
}

public struct LocalAppTarget: Codable, Equatable, Sendable {
    public var appName: String
    public var bundleIdentifier: String?
    public var titleContains: String?
    public var metadata: [String: String]

    public init(
        appName: String,
        bundleIdentifier: String? = nil,
        titleContains: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.titleContains = titleContains
        self.metadata = metadata
    }
}

public struct TaskIntent: Codable, Equatable, Sendable {
    public var intentID: String
    public var taskType: String
    public var targetApp: LocalAppTarget
    public var entities: [String: String]
    public var normalizedEntities: [String: String]
    public var confidence: Double
    public var parserSource: TaskIntentParserSource
    public var needsConfirmation: Bool
    public var sourceModelCallID: String?
    public var metadata: [String: String]

    public init(
        intentID: String,
        taskType: String,
        targetApp: LocalAppTarget,
        entities: [String: String] = [:],
        normalizedEntities: [String: String] = [:],
        confidence: Double,
        parserSource: TaskIntentParserSource,
        needsConfirmation: Bool = false,
        sourceModelCallID: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.intentID = intentID
        self.taskType = taskType
        self.targetApp = targetApp
        self.entities = entities
        self.normalizedEntities = normalizedEntities
        self.confidence = min(max(confidence, 0), 1)
        self.parserSource = parserSource
        self.needsConfirmation = needsConfirmation
        self.sourceModelCallID = sourceModelCallID
        self.metadata = metadata
    }
}

public struct LocalAppTaskEntityRule: Codable, Equatable, Sendable {
    public var name: String
    public var markers: [String]
    public var aliases: [String: String]
    public var required: Bool
    public var metadata: [String: String]

    public init(
        name: String,
        markers: [String] = [],
        aliases: [String: String] = [:],
        required: Bool = true,
        metadata: [String: String] = [:]
    ) {
        self.name = name
        self.markers = markers
        self.aliases = aliases
        self.required = required
        self.metadata = metadata
    }
}

public enum LocalAppTaskStepRole: String, Codable, Equatable, Sendable {
    case parseIntent
    case launchOrFocusApp
    case observeApp
    case focusControl
    case enterText
    case submit
    case verifyResult
    case custom
}

public struct LocalAppTaskWorkflowStepDefinition: Codable, Equatable, Sendable {
    public var id: String
    public var role: LocalAppTaskStepRole
    public var summary: String
    public var metadata: [String: String]

    public init(
        id: String,
        role: LocalAppTaskStepRole,
        summary: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.role = role
        self.summary = summary
        self.metadata = metadata
    }
}

public enum LocalAppObservationStrategy: String, Codable, Equatable, Sendable {
    case accessibility
    case windowMetadata
    case screenshotForLocalModel = "screenshot_for_local_model"
    case screenshotOCR = "screenshot_ocr"
}

public struct LocalAppTaskDefinition: Codable, Equatable, Sendable {
    public var taskType: String
    public var targetApp: LocalAppTarget
    public var triggerTerms: [String]
    public var entityRules: [LocalAppTaskEntityRule]
    public var workflowSteps: [LocalAppTaskWorkflowStepDefinition]
    public var observationStrategies: [LocalAppObservationStrategy]
    public var verificationEntityName: String?
    public var metadata: [String: String]

    public init(
        taskType: String,
        targetApp: LocalAppTarget,
        triggerTerms: [String],
        entityRules: [LocalAppTaskEntityRule] = [],
        workflowSteps: [LocalAppTaskWorkflowStepDefinition] = [],
        observationStrategies: [LocalAppObservationStrategy] = [.accessibility, .windowMetadata, .screenshotForLocalModel],
        verificationEntityName: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.taskType = taskType
        self.targetApp = targetApp
        self.triggerTerms = triggerTerms
        self.entityRules = entityRules
        self.workflowSteps = workflowSteps
        self.observationStrategies = observationStrategies
        self.verificationEntityName = verificationEntityName
        self.metadata = metadata
    }
}

public enum LocalAppTaskStepStatus: String, Codable, Equatable, Sendable {
    case projected
    case blocked
    case verified
}

public enum LocalAppTaskTerminalState: String, Codable, Equatable, Sendable {
    case completed
    case needsUserReview = "needs-user-review"
    case failedSafe = "failed-safe"
    case timedOut = "timed-out"
}

public struct LocalAppTaskObservation: Codable, Equatable, Sendable {
    public var appIsRunning: Bool
    public var appIsFocused: Bool
    public var availableControls: [String: Bool]
    public var visibleText: [String: String]
    public var confidence: Double
    public var metadata: [String: String]

    public init(
        appIsRunning: Bool = false,
        appIsFocused: Bool = false,
        availableControls: [String: Bool] = [:],
        visibleText: [String: String] = [:],
        confidence: Double = 0,
        metadata: [String: String] = [:]
    ) {
        self.appIsRunning = appIsRunning
        self.appIsFocused = appIsFocused
        self.availableControls = availableControls
        self.visibleText = visibleText
        self.confidence = min(max(confidence, 0), 1)
        self.metadata = metadata
    }
}

public struct LocalAppTaskDryRunStep: Codable, Equatable, Sendable {
    public var id: String
    public var role: LocalAppTaskStepRole
    public var status: LocalAppTaskStepStatus
    public var summary: String
    public var metadata: [String: String]

    public init(
        id: String,
        role: LocalAppTaskStepRole,
        status: LocalAppTaskStepStatus,
        summary: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.role = role
        self.status = status
        self.summary = summary
        self.metadata = metadata
    }
}

public struct LocalAppTaskDryRunPlan: Codable, Equatable, Sendable {
    public var intent: TaskIntent
    public var targetApp: LocalAppTarget
    public var steps: [LocalAppTaskDryRunStep]
    public var terminalState: LocalAppTaskTerminalState
    public var canAttemptGuardedLive: Bool
    public var verificationConfidence: Double
    public var metadata: [String: String]

    public init(
        intent: TaskIntent,
        targetApp: LocalAppTarget,
        steps: [LocalAppTaskDryRunStep],
        terminalState: LocalAppTaskTerminalState,
        canAttemptGuardedLive: Bool,
        verificationConfidence: Double,
        metadata: [String: String] = [:]
    ) {
        self.intent = intent
        self.targetApp = targetApp
        self.steps = steps
        self.terminalState = terminalState
        self.canAttemptGuardedLive = canAttemptGuardedLive
        self.verificationConfidence = min(max(verificationConfidence, 0), 1)
        self.metadata = metadata
    }
}
