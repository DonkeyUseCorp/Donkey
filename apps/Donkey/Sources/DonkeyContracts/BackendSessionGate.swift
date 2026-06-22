import Foundation

/// Process-wide authority on whether the hosted backend session is currently usable.
///
/// The auth coordinator is the single writer: it flips this as the session is established, expires, or
/// is signed out. Every backend caller and always-on background loop reads it. When the session is
/// signed out, `DonkeyBackendInferenceClient` short-circuits each request to `.authenticationRequired`
/// without a network round trip, and the warm-cache / UI-understanding loops skip their work — so a
/// logged-out app stops hammering the backend with guaranteed-401 calls instead of retrying forever.
///
/// It defaults to authenticated so first launch, tests, and dev-bypass paths behave exactly as before
/// until the auth coordinator says otherwise.
public final class BackendSessionGate: @unchecked Sendable {
    public static let shared = BackendSessionGate()

    private let lock = NSLock()
    private var isAuthenticatedStorage = true

    public init() {}

    /// Whether backend calls should be attempted. False once the session is signed out.
    public var isAuthenticated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isAuthenticatedStorage
    }

    public func update(isAuthenticated: Bool) {
        lock.lock()
        isAuthenticatedStorage = isAuthenticated
        lock.unlock()
    }
}
