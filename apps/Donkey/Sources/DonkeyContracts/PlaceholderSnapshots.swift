import Foundation

public struct RuntimeStatusSnapshot: Equatable, Sendable {
    public var isReady: Bool
    public var summary: String
    public var sourcePlan: String
    public var lifecycleState: RunLifecycleState
    public var latestEventSummary: String?
    public var eventCount: Int
    public var requiresInputRelease: Bool

    public init(
        isReady: Bool,
        summary: String,
        sourcePlan: String,
        lifecycleState: RunLifecycleState = .idle,
        latestEventSummary: String? = nil,
        eventCount: Int = 0,
        requiresInputRelease: Bool = false
    ) {
        self.isReady = isReady
        self.summary = summary
        self.sourcePlan = sourcePlan
        self.lifecycleState = lifecycleState
        self.latestEventSummary = latestEventSummary
        self.eventCount = eventCount
        self.requiresInputRelease = requiresInputRelease
    }
}

public struct AIHarnessSnapshot: Equatable, Sendable {
    public var isPlannerAvailable: Bool
    public var suggestedPromptText: String
    public var sourcePlan: String

    public init(
        isPlannerAvailable: Bool,
        suggestedPromptText: String,
        sourcePlan: String
    ) {
        self.isPlannerAvailable = isPlannerAvailable
        self.suggestedPromptText = suggestedPromptText
        self.sourcePlan = sourcePlan
    }
}
