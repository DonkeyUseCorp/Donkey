import DonkeyContracts
import Foundation

public protocol RuntimeStatusProviding: Sendable {
    func snapshot() -> RuntimeStatusSnapshot
}

public struct OffTheShelfRunLoopBoundary: RuntimeStatusProviding {
    public init() {}

    public func snapshot() -> RuntimeStatusSnapshot {
        RuntimeStatusSnapshot(
            isReady: false,
            summary: "Real-time run loop integration boundary",
            sourcePlan: "plans/20-off-the-shelf-run-loop.md"
        )
    }
}
