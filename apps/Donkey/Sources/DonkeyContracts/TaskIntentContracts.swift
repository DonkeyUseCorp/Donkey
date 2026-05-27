import Foundation

public enum TaskIntentParserSource: String, Codable, Equatable, Sendable {
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

public enum LocalAppFinderSupportStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case supported
    case candidate
    case unsupported
    case denied
}

public struct LocalAppFinderCapability: Codable, Equatable, Sendable {
    public var id: String
    public var summary: String
    public var controlProfiles: [String]
    public var requiredEntities: [String]

    public init(
        id: String,
        summary: String,
        controlProfiles: [String] = [],
        requiredEntities: [String] = []
    ) {
        self.id = id
        self.summary = summary
        self.controlProfiles = controlProfiles
        self.requiredEntities = requiredEntities
    }
}

public struct LocalAppFinderCatalogEntry: Codable, Equatable, Sendable {
    public var appID: String
    public var appName: String
    public var bundleIdentifier: String?
    public var description: String
    public var supportStatus: LocalAppFinderSupportStatus
    public var capabilities: [LocalAppFinderCapability]
    public var denyReason: String?
    public var metadata: [String: String]

    public init(
        appID: String,
        appName: String,
        bundleIdentifier: String? = nil,
        description: String,
        supportStatus: LocalAppFinderSupportStatus,
        capabilities: [LocalAppFinderCapability] = [],
        denyReason: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.appID = appID
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.description = description
        self.supportStatus = supportStatus
        self.capabilities = capabilities
        self.denyReason = denyReason
        self.metadata = metadata
    }
}

public enum LocalAppActionPlanTool: String, Codable, CaseIterable, Equatable, Sendable {
    case openOrFocusApp = "app.openOrFocus"
    case observeApp = "app.observe"
    case newDocument = "ui.newDocument"
    case focusSearch = "ui.focusSearch"
    case focusAddressBar = "ui.focusAddressBar"
    case focusTextEntry = "ui.focusTextEntry"
    case setText = "ui.setText"
    case clickTarget = "ui.clickTarget"
    case pressReturn = "ui.pressReturn"
    case verifyCommand = "app.verifyCommand"
    case verifyVisibleText = "app.verifyVisibleText"
}

public struct LocalAppActionPlan: Codable, Equatable, Sendable {
    public var tools: [LocalAppActionPlanTool]
    public var inputEntity: String
    public var controlID: String
    public var focusKey: String
    public var verificationTools: [LocalAppActionPlanTool]

    public init(
        tools: [LocalAppActionPlanTool],
        inputEntity: String = "query",
        controlID: String = "search",
        focusKey: String = "Command+F",
        verificationTools: [LocalAppActionPlanTool] = [.verifyCommand]
    ) {
        self.tools = tools
        self.inputEntity = inputEntity
        self.controlID = controlID
        self.focusKey = focusKey
        let normalizedVerificationTools = verificationTools.filter(Self.isVerificationTool)
        self.verificationTools = normalizedVerificationTools.isEmpty
            ? tools.filter(Self.isVerificationTool)
            : normalizedVerificationTools
    }

    public static var defaultSearchSubmitPlan: LocalAppActionPlan {
        LocalAppActionPlan(
            tools: [
                .openOrFocusApp,
                .observeApp,
                .focusSearch,
                .setText,
                .pressReturn,
                .verifyCommand
            ]
        )
    }

    public var isExecutable: Bool {
        tools.isEmpty == false
            && tools.contains(where: { $0 == .setText || $0 == .pressReturn })
    }

    public var requiresTextInput: Bool {
        tools.contains(.setText)
    }

    public var requiresVisibleTextVerification: Bool {
        verificationTools.contains(.verifyVisibleText)
    }

    public static func isVerificationTool(_ tool: LocalAppActionPlanTool) -> Bool {
        tool == .verifyCommand || tool == .verifyVisibleText
    }

    private enum CodingKeys: String, CodingKey {
        case tools
        case inputEntity
        case controlID
        case focusKey
        case verificationTools
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tools = try container.decode([LocalAppActionPlanTool].self, forKey: .tools)
        let verificationTools = try container.decodeIfPresent([LocalAppActionPlanTool].self, forKey: .verificationTools)
            ?? tools.filter(Self.isVerificationTool)
        self.init(
            tools: tools,
            inputEntity: try container.decode(String.self, forKey: .inputEntity),
            controlID: try container.decode(String.self, forKey: .controlID),
            focusKey: try container.decode(String.self, forKey: .focusKey),
            verificationTools: verificationTools
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tools, forKey: .tools)
        try container.encode(inputEntity, forKey: .inputEntity)
        try container.encode(controlID, forKey: .controlID)
        try container.encode(focusKey, forKey: .focusKey)
        try container.encode(verificationTools, forKey: .verificationTools)
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
    public var actionPlan: LocalAppActionPlan?
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
        actionPlan: LocalAppActionPlan? = nil,
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
        self.actionPlan = actionPlan
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

public enum LocalAppTaskWorkflowStage: String, Codable, CaseIterable, Equatable, Sendable {
    case parseIntent
    case resolveApp
    case observe
    case evidencePlan = "evidence-plan"
    case approval
    case execute
    case verify
}

public enum LocalAppTaskWorkflowStageStatus: String, Codable, Equatable, Sendable {
    case pending
    case started
    case completed
    case waiting
    case skipped
    case blocked
    case failed
}

public struct LocalAppTaskWorkflowStageState: Codable, Equatable, Sendable {
    public var stage: LocalAppTaskWorkflowStage
    public var status: LocalAppTaskWorkflowStageStatus
    public var summary: String
    public var metadata: [String: String]

    public init(
        stage: LocalAppTaskWorkflowStage,
        status: LocalAppTaskWorkflowStageStatus = .pending,
        summary: String = "",
        metadata: [String: String] = [:]
    ) {
        self.stage = stage
        self.status = status
        self.summary = summary
        self.metadata = metadata
    }
}

public struct LocalAppTaskWorkflowProgress: Codable, Equatable, Sendable {
    public var stages: [LocalAppTaskWorkflowStageState]
    public var metadata: [String: String]

    public init(
        stages: [LocalAppTaskWorkflowStageState] = [],
        metadata: [String: String] = [:]
    ) {
        self.stages = stages
        self.metadata = metadata
    }

    public func state(for stage: LocalAppTaskWorkflowStage) -> LocalAppTaskWorkflowStageState? {
        stages.first { $0.stage == stage }
    }
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
    case needsEvidence = "needs-evidence"
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

public struct LocalAppEvidenceBackedActionStep: Codable, Equatable, Sendable {
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

public struct LocalAppEvidenceBackedActionPlan: Codable, Equatable, Sendable {
    public var intent: TaskIntent
    public var targetApp: LocalAppTarget
    public var steps: [LocalAppEvidenceBackedActionStep]
    public var terminalState: LocalAppTaskTerminalState
    public var canExecuteGuardedActions: Bool
    public var verificationConfidence: Double
    public var metadata: [String: String]

    public init(
        intent: TaskIntent,
        targetApp: LocalAppTarget,
        steps: [LocalAppEvidenceBackedActionStep],
        terminalState: LocalAppTaskTerminalState,
        canExecuteGuardedActions: Bool,
        verificationConfidence: Double,
        metadata: [String: String] = [:]
    ) {
        self.intent = intent
        self.targetApp = targetApp
        self.steps = steps
        self.terminalState = terminalState
        self.canExecuteGuardedActions = canExecuteGuardedActions
        self.verificationConfidence = min(max(verificationConfidence, 0), 1)
        self.metadata = metadata
    }
}
