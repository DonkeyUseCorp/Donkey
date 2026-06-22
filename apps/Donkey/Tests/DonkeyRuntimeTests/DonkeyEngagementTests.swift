import Foundation
import Testing
@testable import DonkeyAI

@Suite
struct DonkeyEngagementTests {
    /// Drives the tracker's clock from the test so window expiry is deterministic.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var nowMS: Double = 0
        func read() -> Double { lock.lock(); defer { lock.unlock() }; return nowMS }
        func advance(_ ms: Double) { lock.lock(); nowMS += ms; lock.unlock() }
    }

    @Test
    func idleByDefault() {
        let engagement = DonkeyEngagement(uptimeMS: { 0 })
        #expect(!engagement.isEngaged(), "Nothing submitted or running: not engaged.")
    }

    @Test
    func interactionOpensWindowThenExpires() {
        let clock = Clock()
        let engagement = DonkeyEngagement(uptimeMS: clock.read)
        engagement.noteInteraction()
        #expect(engagement.isEngaged(windowMS: 1_000), "Just interacted: engaged.")
        clock.advance(999)
        #expect(engagement.isEngaged(windowMS: 1_000), "Inside the window: still engaged.")
        clock.advance(2)
        #expect(!engagement.isEngaged(windowMS: 1_000), "Past the window: idled out.")
    }

    @Test
    func activeRunStaysEngagedRegardlessOfWindow() {
        let clock = Clock()
        let engagement = DonkeyEngagement(uptimeMS: clock.read)
        engagement.beginRun()
        clock.advance(10_000)
        #expect(engagement.isEngaged(windowMS: 1_000), "A run in flight is engaged no matter how long.")
        engagement.endRun()
        #expect(engagement.isEngaged(windowMS: 1_000), "endRun stamps an interaction: brief lingering window.")
        clock.advance(1_001)
        #expect(!engagement.isEngaged(windowMS: 1_000), "After the post-run window: idled out.")
    }

    @Test
    func nestedRunsBalanceAndDoNotUnderflow() {
        let clock = Clock()
        let engagement = DonkeyEngagement(uptimeMS: clock.read)
        engagement.beginRun()
        engagement.beginRun()
        engagement.endRun()
        #expect(engagement.isEngaged(windowMS: 1_000), "One run still active: engaged.")
        engagement.endRun()
        // Extra endRun must not drive depth negative and wedge engagement on forever.
        engagement.endRun()
        clock.advance(1_001)
        #expect(!engagement.isEngaged(windowMS: 1_000), "Depth floors at zero; window expires normally.")
    }
}
