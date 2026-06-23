import DonkeyContracts
import DonkeyUI
import Testing

/// The collapsed notch headline narrates the conversation's latest line — never the original prompt
/// title. `UserQueryChinDisplayTests` locks the per-conversation `chinDisplayText`; these lock the headline
/// path the collapsed pill actually renders, where the "still says hi" bug lived: once a reply landed
/// and the user had acknowledged it, the headline fell back to `conversationTitle` and read the prompt again.
///
/// `@MainActor`: the headline helpers live on a SwiftUI `View` and are main-actor-isolated like their
/// production callers, so the suite matches that isolation rather than running off the main actor.
@Suite
@MainActor
struct UserQueryCollapsedHeadlineTests {
    private func conversation(
        title: String,
        detail: String,
        status: UserQueryConversationStatus,
        seen: Bool = false
    ) -> UserQueryConversation {
        UserQueryConversation(
            id: "t",
            title: title,
            detail: detail,
            commandText: title,
            status: status,
            accentIndex: 0,
            metadata: seen ? ["seen": "true"] : [:]
        )
    }

    private let idleState = UserQueryState(promptText: "", leadingSignalLevel: .ready)

    @Test
    func headlineShowsTheReplyNotThePrompt() {
        // The exact bug from the screenshot: prompt "hi", reply in `detail`. The collapsed notch must
        // read back the reply, not the opening "hi" — and this holds whether or not the reply was seen.
        let reply = "Hi there! I'm ready when you are."
        for seen in [false, true] {
            let answered = conversation(title: "hi", detail: reply, status: .chatting, seen: seen)
            #expect(
                UserQueryNotchStatusView.collapsedHeadline(conversations: [answered], state: idleState) == reply
            )
        }
    }

    @Test
    func headlineShowsThePromptOnlyBeforeAnyLineExists() {
        // A conversation that has no conversation line yet (detail empty) legitimately reads back the prompt —
        // this is the one case where the title is the latest thing said, via `chinDisplayText`'s fallback.
        let fresh = conversation(title: "hi", detail: "", status: .running)
        #expect(UserQueryNotchStatusView.collapsedHeadline(conversations: [fresh], state: idleState) == "hi")
    }

    @Test
    func headlineFallsBackToIdleOnceTheLastConversationIsDismissed() {
        // Closing the last row resets the prompt line to rest (see `UserQueryOverlayModel.restingPromptText`),
        // so the collapsed headline reads Idle — not the dismissed conversation's stranded summary.
        #expect(UserQueryNotchStatusView.collapsedHeadline(conversations: [], state: idleState) == "Idle")
    }

    @Test
    func aStrandedSummaryWithNoRowsWouldKeepShowing() {
        // The failure mode the dismiss reset prevents: a finished line left in `promptText` with no rows
        // resurfaces in the headline. If the model stops resetting on dismiss, this is what the user sees —
        // the "still listed" row from the screenshot. The reset keeps this state from ever existing.
        let stranded = UserQueryState(
            promptText: "I'll start by checking the current directory.",
            leadingSignalLevel: .ready
        )
        #expect(UserQueryNotchStatusView.collapsedHeadline(conversations: [], state: stranded) != "Idle")
    }
}
