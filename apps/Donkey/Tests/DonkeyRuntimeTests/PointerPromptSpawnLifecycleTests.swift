import DonkeyContracts
import Testing

@Suite
struct PointerPromptSpawnLifecycleTests {
    @Test
    func completedActionSpawnsCanFadeButConversationStaysReadable() {
        #expect(!PointerPromptSpawnLifecycle.keepsVisibleResult(for: .completed))
        #expect(PointerPromptSpawnLifecycle.keepsVisibleResult(for: .chatting))
        #expect(PointerPromptSpawnLifecycle.keepsVisibleResult(for: .waitingForClarification))
        #expect(PointerPromptSpawnLifecycle.keepsVisibleResult(for: .waitingForPermission))
        #expect(PointerPromptSpawnLifecycle.keepsVisibleResult(for: .waitingForReview))
        #expect(PointerPromptSpawnLifecycle.keepsVisibleResult(for: .interrupted))
        #expect(PointerPromptSpawnLifecycle.keepsVisibleResult(for: .needsAttention))
        #expect(PointerPromptSpawnLifecycle.keepsVisibleResult(for: .failed))
    }

}
