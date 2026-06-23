import DonkeyContracts
import Foundation
import Testing

@testable import Donkey

/// Closing a conversation with the notch X must make it disappear. The list removal already worked; the
/// bug that kept the row looking "still listed" lived in the *prompt line*: the collapsed notch falls back
/// to `promptState` only when no conversation row exists, so a dismissed conversation's summary left
/// stranded in `promptText` kept rendering (with a generic "Needs attention") as though the row were still
/// there. `dismissTask` now returns the line to rest once the list empties; these lock that decision.
/// `@MainActor`: `restingPromptText` is a static helper on the main-actor-isolated model, so the suite
/// runs on the main actor to call it — matching the model's other static-helper tests.
@Suite
@MainActor
struct UserQueryDismissPromptResetTests {
    private func task(id: String, status: UserQueryConversationStatus) -> UserQueryConversation {
        UserQueryConversation(
            id: id,
            title: "prompt",
            detail: "I'll start by checking the current directory.",
            commandText: "prompt",
            status: status,
            accentIndex: 0
        )
    }

    @Test
    func dismissingTheLastConversationReturnsThePromptLineToRest() {
        // No rows left: the line must reset to the resting placeholder so the collapsed notch reads Idle,
        // never the dismissed conversation's stranded summary.
        #expect(
            UserQueryOverlayModel.restingPromptText(forRemainingConversations: []) == UserQueryCopy.defaultPromptPlaceholder
        )
    }

    @Test
    func dismissingWithConversationsRemainingLeavesThePromptLineToTheList() {
        // Rows remain: the collapsed notch reads them directly, so the prompt line is left untouched (nil)
        // rather than overwritten — the surviving conversation, not the placeholder, drives the display.
        let remaining = [task(id: "a", status: .running)]
        #expect(UserQueryOverlayModel.restingPromptText(forRemainingConversations: remaining) == nil)
    }
}
