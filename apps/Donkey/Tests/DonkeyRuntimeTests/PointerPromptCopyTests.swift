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
            PointerPromptCopy.composerPlaceholder(for: "I couldn't find a supported local action for that yet.") ==
                PointerPromptCopy.defaultPromptPlaceholder
        )
        #expect(
            PointerPromptCopy.composerPlaceholder(for: "play some justin bieber") ==
                PointerPromptCopy.defaultPromptPlaceholder
        )
        #expect(PointerPromptCopy.composerPlaceholder(for: "Listening...") == "Listening...")
    }
}
