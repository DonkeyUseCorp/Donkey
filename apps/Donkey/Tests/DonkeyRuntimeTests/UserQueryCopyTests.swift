import DonkeyAI
import DonkeyContracts
import Testing

@Suite
struct UserQueryCopyTests {
    @Test
    func defaultPromptCopyIsSharedAcrossPromptSurfaces() {
        #expect(UserQueryState.productionDefault.promptText == UserQueryCopy.defaultPromptPlaceholder)
        #expect(AIHarnessBoundary().snapshot().suggestedPromptText == UserQueryCopy.defaultPromptPlaceholder)
    }

    @Test
    func placeholderCopyDoesNotBecomeTaskDisplayText() {
        #expect(!UserQueryCopy.isTaskDisplayText(UserQueryCopy.defaultPromptPlaceholder))
        #expect(!UserQueryCopy.isTaskDisplayText("  \(UserQueryCopy.defaultPromptPlaceholder)  "))
        #expect(UserQueryCopy.isTaskDisplayText("Open Safari"))
    }

    @Test
    func composerPlaceholderDoesNotReuseTaskOrResultText() {
        #expect(
            UserQueryCopy.composerPlaceholder(for: "I can help, but I need a clearer request before opening an app.") ==
                UserQueryCopy.defaultPromptPlaceholder
        )
        #expect(
            UserQueryCopy.composerPlaceholder(for: "play sample track") ==
                UserQueryCopy.defaultPromptPlaceholder
        )
        #expect(UserQueryCopy.composerPlaceholder(for: "Listening...") == "Listening...")
    }
}
