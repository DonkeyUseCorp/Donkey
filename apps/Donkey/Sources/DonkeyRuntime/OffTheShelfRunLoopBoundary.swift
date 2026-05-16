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
            summary: "Run coordinator ready to create sessions",
            lifecycleState: .idle
        )
    }

    public func makeCoordinator(
        contextAssembler: RunContextAssembler = RunContextAssembler()
    ) -> RunCoordinator {
        RunCoordinator(contextAssembler: contextAssembler)
    }
}
