import Foundation

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

