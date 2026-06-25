import DonkeyContracts
import Foundation
import Testing
@testable import Donkey
@testable import DonkeyUI

/// Elapsed time is cumulative per conversation: it counts every stretch the loop actually ran and is
/// monotonic across gates, pauses, and resumes — it never restarts until the conversation reaches a terminal
/// state. The clock lives in two `private(set)` fields mutated only by `openRunningStretch` /
/// `closeRunningStretch`, so "restamp the clock without banking" is uncompilable. These lock that guarantee,
/// the full multi-gate run that originally regressed, and survival across an app interruption.
@MainActor
@Suite
struct ConversationElapsedTimeTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func conversation(
        status: UserQueryConversationStatus,
        createdAt: Date,
        updatedAt: Date? = nil,
        accumulatedActiveSeconds: Double = 0
    ) -> UserQueryConversation {
        UserQueryConversation(
            id: "c",
            title: "Clip the video",
            detail: "Working",
            commandText: "clip the video",
            status: status,
            accentIndex: 0,
            createdAt: createdAt,
            updatedAt: updatedAt ?? createdAt,
            accumulatedActiveSeconds: accumulatedActiveSeconds
        )
    }

    @Test
    func elapsedIsBankedTotalPlusTheOpenStretchWhileRunning() {
        // 120s banked from earlier stretches + 30s into the open one = 150s, not a fresh 30s.
        let running = conversation(status: .running, createdAt: t0, accumulatedActiveSeconds: 120)
        #expect(running.activeSeconds(asOf: t0.addingTimeInterval(30)) == 150)
    }

    @Test
    func elapsedFreezesAtTheBankedTotalWhileStopped() {
        // Gated/paused: no open stretch, so the clock holds at the banked total and the idle wait is ignored.
        let waiting = conversation(status: .waitingForPermission, createdAt: t0, accumulatedActiveSeconds: 120)
        #expect(waiting.runningSince == nil)
        #expect(waiting.activeSeconds(asOf: t0.addingTimeInterval(9_999)) == 120)
    }

    @Test
    func openingAStretchThatIsAlreadyOpenNeverRestartsTheClock() {
        // The exact bug class: a re-entry into running (a per-step update, an approved gate) must not reset
        // the anchor. Opening is a no-op while a stretch is already open, so the clock keeps counting.
        var running = conversation(status: .running, createdAt: t0)
        running.openRunningStretch(asOf: t0.addingTimeInterval(50))
        #expect(running.runningSince == t0)                              // anchor unmoved
        #expect(running.activeSeconds(asOf: t0.addingTimeInterval(50)) == 50)  // 50s, not 0
    }

    @Test
    func closingAStretchTwiceBanksItOnlyOnce() {
        // Closing when nothing is open is a no-op, so a repeated terminal write can't double-count or shrink
        // the total.
        var running = conversation(status: .running, createdAt: t0)
        running.closeRunningStretch(asOf: t0.addingTimeInterval(60))
        running.closeRunningStretch(asOf: t0.addingTimeInterval(200))
        #expect(running.accumulatedActiveSeconds == 60)
        #expect(running.runningSince == nil)
    }

    @Test
    func aMultiGateRunStaysCumulativeAndExcludesIdleWaits() {
        // The scenario that regressed: a shell-heavy task that gates on each command. Every approve re-enters
        // running; the clock must continue, counting only active time.
        var c = conversation(status: .running, createdAt: t0)        // open at t0
        c.closeRunningStretch(asOf: t0.addingTimeInterval(60))       // ran 60s, hit a gate
        #expect(c.activeSeconds(asOf: t0.addingTimeInterval(9_999)) == 60)  // frozen while waiting
        c.openRunningStretch(asOf: t0.addingTimeInterval(90))        // approved 30s later
        c.closeRunningStretch(asOf: t0.addingTimeInterval(130))      // ran 40s more, next gate
        #expect(c.accumulatedActiveSeconds == 100)                   // 60 + 40 — the 30s idle excluded
    }

    @Test
    func theBankedTotalSurvivesAnInterruption() {
        // "Persist if interrupted": a brand-new store instance reading the same file (a relaunch) must see
        // the banked total, not 0.
        let url = Self.tempStoreURL()
        let writer = CoreDataUserQueryConversationStore(storeURL: url)
        writer.upsertConversation(conversation(status: .paused, createdAt: t0, accumulatedActiveSeconds: 312))

        let afterRelaunch = CoreDataUserQueryConversationStore(storeURL: url)
        let restored = afterRelaunch.loadRecentConversations(limit: 10).first { $0.id == "c" }
        #expect(restored?.accumulatedActiveSeconds == 312)
    }

    @Test
    func theOpenStretchAnchorSurvivesAnInterruption() {
        // A conversation running when saved keeps its anchor across a relaunch, so the in-flight stretch can
        // be banked at its real end rather than lost.
        let url = Self.tempStoreURL()
        let writer = CoreDataUserQueryConversationStore(storeURL: url)
        let anchor = t0.addingTimeInterval(-90)
        writer.upsertConversation(conversation(status: .running, createdAt: anchor, accumulatedActiveSeconds: 40))

        let afterRelaunch = CoreDataUserQueryConversationStore(storeURL: url)
        let restored = afterRelaunch.loadRecentConversations(limit: 10).first { $0.id == "c" }
        #expect(restored?.runningSince != nil)
        #expect(abs((restored?.runningSince ?? .distantPast).timeIntervalSince(anchor)) < 1)
    }

    @Test
    func relaunchBanksTheInFlightStretchSoTheClockContinues() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        // Running when the app quit: 200s banked, plus a stretch that started 160s ago and last advanced 60s
        // ago (inside the auto-resume window).
        let beforeQuit = conversation(
            status: .running,
            createdAt: now.addingTimeInterval(-160),
            updatedAt: now.addingTimeInterval(-60),
            accumulatedActiveSeconds: 200
        )

        let (restored, autoResumeIDs) = UserQueryOverlayModel.restoredConversations(from: [beforeQuit], now: now)
        let resumed = try! #require(restored.first { $0.id == "c" })

        // The in-flight stretch is banked at its REAL end (updatedAt - anchor = 100s), never the app-closed
        // gap — on top of the 200s for a 300s cumulative total.
        #expect(resumed.accumulatedActiveSeconds == 300)
        #expect(resumed.runningSince == now)            // reopened at relaunch, so the clock continues
        #expect(autoResumeIDs.contains("c"))
        #expect(resumed.activeSeconds(asOf: now) == 300)
    }

    private static func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("conversations.sqlite")
    }
}
