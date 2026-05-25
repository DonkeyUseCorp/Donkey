import DonkeyAI
import DonkeyContracts
import Testing

@Suite
struct PointerPromptCopyTests {
    @Test
    func defaultPromptCopyIsSharedAcrossPromptSurfaces() {
        #expect(PointerPromptState.productionDefault.promptText == PointerPromptCopy.defaultPromptPlaceholder)
        #expect(AIHarnessBoundary().snapshot().suggestedPromptText == PointerPromptCopy.defaultPromptPlaceholder)
    }

    @Test
    func placeholderCopyDoesNotBecomeTaskDisplayText() {
        #expect(!PointerPromptCopy.isTaskDisplayText(PointerPromptCopy.defaultPromptPlaceholder))
        #expect(!PointerPromptCopy.isTaskDisplayText("  \(PointerPromptCopy.defaultPromptPlaceholder)  "))
        #expect(PointerPromptCopy.isTaskDisplayText("Open Safari"))
    }

    @Test
    func composerPlaceholderDoesNotReuseTaskOrResultText() {
        #expect(
            PointerPromptCopy.composerPlaceholder(for: "I can help, but I need a clearer request before opening an app.") ==
                PointerPromptCopy.defaultPromptPlaceholder
        )
        #expect(
            PointerPromptCopy.composerPlaceholder(for: "play some justin bieber") ==
                PointerPromptCopy.defaultPromptPlaceholder
        )
        #expect(PointerPromptCopy.composerPlaceholder(for: "Listening...") == "Listening...")
    }
}
