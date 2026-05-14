import Foundation

public struct RuntimeStatusSnapshot: Equatable, Sendable {
    public var isReady: Bool
    public var summary: String
    public var sourcePlan: String

    public init(isReady: Bool, summary: String, sourcePlan: String) {
        self.isReady = isReady
        self.summary = summary
        self.sourcePlan = sourcePlan
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
