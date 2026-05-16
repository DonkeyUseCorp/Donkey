import Foundation

public struct RuntimeStatusSnapshot: Equatable, Sendable {
    public var isReady: Bool
    public var summary: String
    public var lifecycleState: RunLifecycleState
    public var latestEventSummary: String?
    public var eventCount: Int
    public var requiresInputRelease: Bool

    public init(
        isReady: Bool,
        summary: String,
        lifecycleState: RunLifecycleState = .idle,
        latestEventSummary: String? = nil,
        eventCount: Int = 0,
        requiresInputRelease: Bool = false
    ) {
        self.isReady = isReady
        self.summary = summary
        self.lifecycleState = lifecycleState
        self.latestEventSummary = latestEventSummary
        self.eventCount = eventCount
        self.requiresInputRelease = requiresInputRelease
    }
}

public struct AIHarnessSnapshot: Equatable, Sendable {
    public var isPlannerAvailable: Bool
    public var suggestedPromptText: String

    public init(
        isPlannerAvailable: Bool,
        suggestedPromptText: String
    ) {
        self.isPlannerAvailable = isPlannerAvailable
        self.suggestedPromptText = suggestedPromptText
    }
}
