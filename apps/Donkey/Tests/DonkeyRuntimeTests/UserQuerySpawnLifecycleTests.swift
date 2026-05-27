import DonkeyContracts
import Testing

@Suite
struct UserQuerySpawnLifecycleTests {
    @Test
    func completedActionSpawnsCanFadeButConversationStaysReadable() {
        #expect(!UserQuerySpawnLifecycle.keepsVisibleResult(for: .completed))
        #expect(UserQuerySpawnLifecycle.keepsVisibleResult(for: .chatting))
        #expect(UserQuerySpawnLifecycle.keepsVisibleResult(for: .waitingForClarification))
        #expect(UserQuerySpawnLifecycle.keepsVisibleResult(for: .waitingForPermission))
        #expect(UserQuerySpawnLifecycle.keepsVisibleResult(for: .waitingForReview))
        #expect(UserQuerySpawnLifecycle.keepsVisibleResult(for: .interrupted))
        #expect(UserQuerySpawnLifecycle.keepsVisibleResult(for: .needsAttention))
        #expect(UserQuerySpawnLifecycle.keepsVisibleResult(for: .failed))
    }

}
