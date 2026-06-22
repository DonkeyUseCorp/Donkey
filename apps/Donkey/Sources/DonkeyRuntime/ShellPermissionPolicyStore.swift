import Foundation

/// Remembers shell-command consent decisions.
///
/// Two layers:
/// - **Always-allow** rules, keyed on a command signature (e.g. `defaults write`,
///   `open`), persisted to disk so they survive across runs — the "always allow"
///   choice. `highRisk` signatures are never written here.
/// - A transient **allow-once** ledger held only in memory: when the user picks
///   "allow once", the deciding command's signature is granted a single use for
///   that task and consumed the next time the executor runs it, so it can never
///   silently become a standing rule.
public actor ShellPermissionPolicyStore {
    public static let shared = ShellPermissionPolicyStore()

    private let storeURL: URL
    private var alwaysAllowed: Set<String>
    private var loaded = false
    /// One-shot grants keyed `"agentID\u{1}signature"`, consumed on first use.
    private var onceGrants: Set<String> = []

    public init(storeURL: URL? = nil) {
        self.storeURL = storeURL ?? Self.defaultStoreURL()
        self.alwaysAllowed = []
    }

    private static func defaultStoreURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Donkey", isDirectory: true)
            .appendingPathComponent("HarnessStore", isDirectory: true)
            .appendingPathComponent("shell-permissions.json")
    }

    // MARK: - Always-allow (persistent)

    public func isAlwaysAllowed(_ signature: String) -> Bool {
        load()
        return alwaysAllowed.contains(signature)
    }

    /// Persist a standing "always allow" rule. Refuses `highRisk` signatures —
    /// those must be re-consented every time.
    public func allowAlways(_ signature: String, tier: ShellRiskTier) {
        guard tier != .highRisk, !signature.isEmpty else { return }
        load()
        guard !alwaysAllowed.contains(signature) else { return }
        alwaysAllowed.insert(signature)
        save()
    }

    public func revokeAlways(_ signature: String) {
        load()
        guard alwaysAllowed.contains(signature) else { return }
        alwaysAllowed.remove(signature)
        save()
    }

    public func allAlwaysAllowed() -> Set<String> {
        load()
        return alwaysAllowed
    }

    // MARK: - Allow-once (transient)

    public func grantOnce(agentID: String, signature: String) {
        guard !signature.isEmpty else { return }
        onceGrants.insert(Self.onceKey(agentID: agentID, signature: signature))
    }

    /// Returns true and removes the grant if a one-shot allowance exists for this
    /// task + signature; false otherwise.
    public func consumeOnce(agentID: String, signature: String) -> Bool {
        let key = Self.onceKey(agentID: agentID, signature: signature)
        guard onceGrants.contains(key) else { return false }
        onceGrants.remove(key)
        return true
    }

    private static func onceKey(agentID: String, signature: String) -> String {
        "\(agentID)\u{1}\(signature)"
    }

    // MARK: - Persistence

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode(PersistedPolicy.self, from: data) else {
            return
        }
        alwaysAllowed = Set(decoded.alwaysAllowedSignatures)
    }

    private func save() {
        let payload = PersistedPolicy(alwaysAllowedSignatures: alwaysAllowed.sorted())
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: storeURL, options: .atomic)
    }

    private struct PersistedPolicy: Codable {
        var alwaysAllowedSignatures: [String]
    }
}
