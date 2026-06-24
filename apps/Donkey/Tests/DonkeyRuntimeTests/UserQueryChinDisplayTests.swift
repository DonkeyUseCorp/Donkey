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

    @Test
    func detailIsMonotonicSoTheChinCanNeverRevertToTheOriginalPrompt() {
        // The structural guarantee the user asked never to revisit: once `detail` holds a real line, ANY
        // write that would blank it is refused by the model itself — so no call site (a stray empty
        // `liveDetail`, a cleared stream, a future writer) can drop the chin back to the title (the
        // original prompt). This makes the stale-prompt bug impossible, not merely unlikely.
        var conversation = task(title: "original prompt", detail: "agent's latest line", status: .running)
        conversation.detail = ""                               // a stray blank write…
        #expect(conversation.detail == "agent's latest line")  // …is refused, the latest line stands
        conversation.detail = "   \n  "                        // whitespace counts as blank…
        #expect(conversation.detail == "agent's latest line")
        #expect(conversation.chinDisplayText == "agent's latest line")
        #expect(conversation.chinDisplayText != "original prompt")
        // A real newer line still moves it forward — monotonic means forward-only, not frozen.
        conversation.detail = "newer line"
        #expect(conversation.chinDisplayText == "newer line")
    }

    @Test
    func resumeLineIsNeverEmptySoTheChinDoesNotRevertToTheStalePrompt() {
        // A resume (gate approval / tap-Resume) announces `.resumed` with no per-call detail, so the chin
        // shows that line until the first step narrates. The line must be non-empty: an empty `detail`
        // makes `chinDisplayText` fall back to `title` — the original prompt the user already sent. The
        // exact bug this guards: after approving a permission gate the chin "reappeared" the opening
        // request instead of live progress.
        let resumeLine = UserQueryActivity(kind: .resumed).displayText
        #expect(!resumeLine.isEmpty)
        let resumed = task(title: "original prompt", detail: resumeLine, status: .running)
        #expect(resumed.chinDisplayText == resumeLine)
        #expect(resumed.chinDisplayText != "original prompt")
    }
}
