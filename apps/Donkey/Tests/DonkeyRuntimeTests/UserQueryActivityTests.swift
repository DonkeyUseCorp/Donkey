import DonkeyContracts
import Foundation
import Testing

@Suite
struct UserQueryActivityTests {
    private func task(
        status: UserQueryConversationStatus,
        detail: String = "",
        metadata: [String: String] = [:]
    ) -> UserQueryConversation {
        UserQueryConversation(
            id: "t",
            title: "Title",
            detail: detail,
            status: status,
            accentIndex: 0,
            metadata: metadata
        )
    }

    @Test
    func displayTextPrefersSummaryThenFallsBackToKindLabel() {
        #expect(UserQueryActivity(kind: .paused).displayText == "Paused")
        #expect(UserQueryActivity(kind: .paused, summary: "Permission denied").displayText == "Permission denied")
    }

    @Test
    func everyKindHasNonEmptyPresentation() {
        for kind in UserQueryActivity.Kind.allCases {
            #expect(!kind.label.isEmpty)
            #expect(!kind.systemImage.isEmpty)
            #expect(!kind.transcriptIcon.isEmpty)
        }
    }

    @Test
    func runningStatusWithNoNarrationReadsAsThinkingNotAnInternalString() {
        // The post-approval / post-resume state: status running, no detail. The line must derive a
        // clean activity label, never a hardcoded "Approved — continuing".
        let activity = UserQueryActivity.current(for: task(status: .running))
        #expect(activity.kind == .working)
        #expect(activity.displayText == "Thinking")
    }

    @Test
    func runningStatusUsesToolHintWhenPresent() {
        let activity = UserQueryActivity.current(for: task(status: .running, metadata: ["activity.tool": "shell_exec"]))
        #expect(activity.kind == .running)
    }

    @Test
    func toolNamesMapToKindsByTypedFieldNotUserText() {
        #expect(UserQueryActivity.kind(forToolNamed: "ax.observe") == .observing)
        #expect(UserQueryActivity.kind(forToolNamed: "shell_exec") == .running)
        #expect(UserQueryActivity.kind(forToolNamed: "user.clarify") == .waitingForInput)
        #expect(UserQueryActivity.kind(forToolNamed: "music.search") == .searching)
        #expect(UserQueryActivity.kind(forToolNamed: "totally.unknown.tool") == .working)
    }

    @Test
    func statusMapsToKind() {
        #expect(UserQueryActivity.kind(forStatus: .waitingForPermission) == .waitingForPermission)
        #expect(UserQueryActivity.kind(forStatus: .completed) == .completed)
        #expect(UserQueryActivity.kind(forStatus: .chatting) == .message)
    }

    @Test
    func transcriptLineCarriesIconForTheRecord() {
        let line = UserQueryActivity(kind: .paused).transcriptLine
        #expect(line.contains("Paused"))
        #expect(line.first.map { !$0.isLetter } == true) // leads with the kind's icon, not the label
    }
}
