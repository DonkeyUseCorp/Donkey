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
        #expect(!UserQueryCopy.isConversationDisplayText(UserQueryCopy.defaultPromptPlaceholder))
        #expect(!UserQueryCopy.isConversationDisplayText("  \(UserQueryCopy.defaultPromptPlaceholder)  "))
        #expect(UserQueryCopy.isConversationDisplayText("Open Safari"))
    }

    /// A transient voice placeholder stranded in `promptText` (e.g. dismissing mid-listen) must not read as
    /// conversation content, or the notch shows a "Listening... / Needs attention" card with no way to clear it.
    @Test
    func transientVoicePlaceholdersAreNeverTaskDisplayText() {
        for placeholder in ["Listening...", "Transcribing...", "No voice captured", "Voice unavailable"] {
            #expect(!UserQueryCopy.isConversationDisplayText(placeholder))
            #expect(!UserQueryCopy.isConversationDisplayText("  \(placeholder)  "))
        }
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
