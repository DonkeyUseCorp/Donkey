import DonkeyContracts
import Foundation

public protocol AIHarnessSnapshotProviding: Sendable {
    func snapshot() -> AIHarnessSnapshot
}

public struct AIHarnessBoundary: AIHarnessSnapshotProviding {
    public init() {}

    public func snapshot() -> AIHarnessSnapshot {
        AIHarnessSnapshot(
            isPlannerAvailable: false,
            suggestedPromptText: UserQueryCopy.defaultPromptPlaceholder
        )
    }
}
