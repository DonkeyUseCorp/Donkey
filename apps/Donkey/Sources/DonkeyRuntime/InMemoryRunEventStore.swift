import DonkeyContracts
import Foundation

public actor InMemoryRunEventStore {
    private var events: [RunEvent] = []
    private var nextSequence = 1

    public init() {}

    @discardableResult
    public func append(_ event: RunEvent) -> RunEvent {
        let sequencedEvent = event.assigningSequence(nextSequence)
        nextSequence += 1
        events.append(sequencedEvent)
        return sequencedEvent
    }

    public func allEvents() -> [RunEvent] {
        events
    }

    public func latestEvent() -> RunEvent? {
        events.last
    }

    public func count() -> Int {
        events.count
    }
}
