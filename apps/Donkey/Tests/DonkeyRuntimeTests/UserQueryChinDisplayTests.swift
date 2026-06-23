import DonkeyContracts
import Foundation
import Testing

/// The collapsed chin shows one line: the latest line of the conversation, which always lives in the
/// task's `detail`. These lock the invariant so a future change can't reintroduce the old bug where the
/// chin reconstructed "what's newest" from the prompt/title/status and got stuck on a stale earlier line.
@Suite
struct UserQueryChinDisplayTests {
    private func task(
        title: String = "first prompt",
        commandText: String = "first prompt",
        detail: String,
        status: UserQueryConversationStatus
    ) -> UserQueryConversation {
        UserQueryConversation(
            id: "t",
            title: title,
            detail: detail,
            commandText: commandText,
            status: status,
            accentIndex: 0
        )
    }

    @Test
    func chinShowsDetailInEveryState() {
        // `detail` is the chin line whether the agent is mid-run or finished — no status branch decides it.
        for status in [UserQueryConversationStatus.running, .chatting, .completed, .waitingForClarification] {
            #expect(task(detail: "latest line", status: status).chinDisplayText == "latest line")
        }
    }

    @Test
    func chinNeverFallsBackToTheStaleCommandText() {
        // The exact bug: a follow-up's reply is in `detail`, but `commandText`/`title` still hold the
        // original prompt. The chin must show the latest line, not read back the opening "hi".
        let answered = task(
            title: "hi",
            commandText: "hi",
            detail: "It's 72°F and sunny.",
            status: .running
        )
        #expect(answered.chinDisplayText == "It's 72°F and sunny.")
    }

    @Test
    func chinFallsBackToTitleOnlyWhenThereIsNoLineYet() {
        #expect(task(title: "hi", detail: "", status: .running).chinDisplayText == "hi")
    }
}
