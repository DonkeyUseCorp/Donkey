import DonkeyContracts
import Foundation
import Testing

@testable import Donkey

/// The first-run tool-bundle download surfaces as a normal-looking conversation, but it is system-driven:
/// the app runs it to completion and the user can't stop, resume, reply to, or dismiss it. That rule is
/// carried by `origin == .system` (so `isUserControllable` is false), and the relaunch restore must never
/// hand a system row to the harness auto-resume — it has no loop behind it. These lock both.
@Suite
@MainActor
struct SystemToolsSetupConversationTests {
    private func conversation(
        id: String,
        status: UserQueryConversationStatus,
        origin: UserQueryConversationOrigin,
        ageMinutes: Double = 1,
        now: Date = Date()
    ) -> UserQueryConversation {
        UserQueryConversation(
            id: id,
            title: id,
            detail: "d",
            status: status,
            accentIndex: 0,
            origin: origin,
            updatedAt: now.addingTimeInterval(-ageMinutes * 60)
        )
    }

    @Test
    func userConversationsAreControllableAndSystemOnesAreNot() {
        // The default origin is `.user`, so every existing call site stays user-controllable.
        #expect(conversation(id: "u", status: .running, origin: .user).isUserControllable)
        #expect(!conversation(id: "s", status: .running, origin: .system).isUserControllable)
    }

    @Test
    func restoredSystemConversationIsNeverAutoResumed() {
        let now = Date()
        // A recently-running USER row auto-resumes; a recently-running SYSTEM row never does, even though
        // it is just as fresh — it has no harness loop to resume, so the install run reconciles it instead.
        let userRow = conversation(id: "user", status: .running, origin: .user, ageMinutes: 1, now: now)
        let systemRow = conversation(id: "system", status: .running, origin: .system, ageMinutes: 1, now: now)

        let result = UserQueryOverlayModel.restoredConversations(from: [userRow, systemRow], now: now)

        #expect(result.autoResumeIDs == ["user"])
        #expect(!result.autoResumeIDs.contains("system"))
    }

    @Test
    func staleRunningSystemConversationCarriesThroughUnchanged() {
        let now = Date()
        // A stale running USER row is downgraded to the retryable `.timedOut`. A system row bypasses that
        // mapping entirely and carries through as-is — the install run, not the restore, decides its fate.
        let staleUser = conversation(id: "user", status: .running, origin: .user, ageMinutes: 120, now: now)
        let staleSystem = conversation(id: "system", status: .running, origin: .system, ageMinutes: 120, now: now)

        let result = UserQueryOverlayModel.restoredConversations(from: [staleUser, staleSystem], now: now)

        func status(_ id: String) -> UserQueryConversationStatus? { result.conversations.first { $0.id == id }?.status }
        #expect(status("user") == .timedOut)
        #expect(status("system") == .running)
        #expect(result.autoResumeIDs.isEmpty)
    }
}
