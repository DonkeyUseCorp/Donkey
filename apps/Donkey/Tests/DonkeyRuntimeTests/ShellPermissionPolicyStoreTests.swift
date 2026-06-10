import DonkeyRuntime
import Foundation
import Testing

@Suite
struct ShellPermissionPolicyStoreTests {
    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("donkey-shell-policy-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("shell-permissions.json")
    }

    @Test
    func alwaysAllowPersistsAcrossInstances() async {
        let url = temporaryStoreURL()
        let store = ShellPermissionPolicyStore(storeURL: url)
        #expect(await store.isAlwaysAllowed("defaults write") == false)
        await store.allowAlways("defaults write", tier: .reversibleWrite)
        #expect(await store.isAlwaysAllowed("defaults write") == true)

        // A fresh instance reading the same file sees the persisted rule.
        let reopened = ShellPermissionPolicyStore(storeURL: url)
        #expect(await reopened.isAlwaysAllowed("defaults write") == true)
    }

    @Test
    func highRiskIsNeverPersistedAsAlwaysAllow() async {
        let store = ShellPermissionPolicyStore(storeURL: temporaryStoreURL())
        await store.allowAlways("rm", tier: .highRisk)
        #expect(await store.isAlwaysAllowed("rm") == false)
    }

    @Test
    func allowOnceIsConsumedExactlyOnce() async {
        let store = ShellPermissionPolicyStore(storeURL: temporaryStoreURL())
        await store.grantOnce(taskID: "t1", signature: "open")
        #expect(await store.consumeOnce(taskID: "t1", signature: "open") == true)
        // Second use is gone.
        #expect(await store.consumeOnce(taskID: "t1", signature: "open") == false)
    }

    @Test
    func allowOnceIsScopedToTaskAndSignature() async {
        let store = ShellPermissionPolicyStore(storeURL: temporaryStoreURL())
        await store.grantOnce(taskID: "t1", signature: "open")
        #expect(await store.consumeOnce(taskID: "t2", signature: "open") == false)
        #expect(await store.consumeOnce(taskID: "t1", signature: "killall") == false)
        #expect(await store.consumeOnce(taskID: "t1", signature: "open") == true)
    }

    @Test
    func revokeRemovesAnAlwaysAllowRule() async {
        let store = ShellPermissionPolicyStore(storeURL: temporaryStoreURL())
        await store.allowAlways("open", tier: .reversibleWrite)
        await store.revokeAlways("open")
        #expect(await store.isAlwaysAllowed("open") == false)
    }
}
