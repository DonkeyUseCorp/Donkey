import DonkeyContracts
import DonkeyUI
import Foundation
import Testing

/// Which conversation the collapsed notch narrates. The "still says hi" bug lived here: once a reply was
/// marked seen it dropped out of the *surfaced* set, selection returned nil, and the notch fell back to
/// the prompt title. These lock the invariant that selection returns the live conversation whenever one
/// exists — including a finished, already-acknowledged reply — so the notch can never revert to the prompt.
///
/// `@MainActor`: the selection lives on a SwiftUI `View`, so it (and its closures) are main-actor-isolated,
/// exactly as its production callers run. The suite matches that isolation so the tests exercise the real code.
@Suite
@MainActor
struct UserQueryCollapsedChinSelectionTests {
    private func conversation(
        id: String,
        title: String = "prompt",
        detail: String,
        status: UserQueryConversationStatus,
        createdAt: Date = Date(timeIntervalSinceReferenceDate: 0)
    ) -> UserQueryConversation {
        UserQueryConversation(
            id: id,
            title: title,
            detail: detail,
            commandText: title,
            status: status,
            accentIndex: 0,
            createdAt: createdAt
        )
    }

    private let now = Date(timeIntervalSinceReferenceDate: 1000)
    private let interval: TimeInterval = 2.6

    private func select(
        conversations: [UserQueryConversation],
        surfaced: [UserQueryConversation]
    ) -> UserQueryConversation? {
        UserQueryNotchStatusView.collapsedChinConversation(
            conversations: conversations, surfaced: surfaced, at: now, rotationInterval: interval
        )
    }

    @Test
    func seenReplyStaysSelectedSoTheNotchNeverRevertsToThePrompt() {
        // The reply is the most recent conversation but has been acknowledged, so it is NOT surfaced.
        // Selection must still return it — never nil — so the chin reads its line, not the prompt title.
        let answered = conversation(id: "a", title: "hi", detail: "Hi there! I'm ready when you are.", status: .chatting)
        let selected = select(conversations: [answered], surfaced: [])
        #expect(selected?.id == "a")
        #expect(selected?.chinDisplayText == "Hi there! I'm ready when you are.")
    }

    @Test
    func nothingSelectedOnlyWhenThereAreNoConversations() {
        #expect(select(conversations: [], surfaced: []) == nil)
    }

    @Test
    func unacknowledgedFailureOutranksEverything() {
        let failed = conversation(id: "f", detail: "Stopped", status: .failed)
        let running = conversation(id: "r", detail: "Working…", status: .running)
        #expect(select(conversations: [running, failed], surfaced: [running, failed])?.id == "f")
    }

    @Test
    func waitingOnUserOutranksRunning() {
        let waiting = conversation(id: "w", detail: "Which file?", status: .waitingForClarification)
        let running = conversation(id: "r", detail: "Working…", status: .running)
        #expect(select(conversations: [running, waiting], surfaced: [running, waiting])?.id == "w")
    }

    @Test
    func mostRecentConversationShowsWhenNothingIsRunning() {
        // A paused thread is still a live conversation item — show its latest line, not an older finished
        // one. Reading the most recent conversation (not only completed/chatting) keeps the live item on screen.
        let paused = conversation(id: "p", detail: "Permission denied", status: .paused)
        let oldDone = conversation(id: "d", detail: "Done earlier", status: .completed)
        #expect(select(conversations: [paused, oldDone], surfaced: [])?.id == "p")
    }
}
