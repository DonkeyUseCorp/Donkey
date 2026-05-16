import DonkeyContracts
import Foundation

public struct RunSessionTicket: Equatable, Sendable {
    public var session: RunSession
    public var droppedBeforeStartCount: Int

    public init(session: RunSession, droppedBeforeStartCount: Int) {
        self.session = session
        self.droppedBeforeStartCount = droppedBeforeStartCount
    }
}

public actor LatestRunSessionQueue {
    private var latestSession: RunSession?
    private var droppedSessionCount = 0

    public init() {}

    public func submit(_ session: RunSession) {
        if latestSession != nil {
            droppedSessionCount += 1
        }

        latestSession = session
    }

    public func nextLatest() -> RunSessionTicket? {
        guard let latestSession else { return nil }

        let ticket = RunSessionTicket(
            session: latestSession,
            droppedBeforeStartCount: droppedSessionCount
        )

        self.latestSession = nil
        droppedSessionCount = 0

        return ticket
    }

    public func pendingSessionCount() -> Int {
        latestSession == nil ? 0 : 1
    }

    public func droppedCount() -> Int {
        droppedSessionCount
    }
}
