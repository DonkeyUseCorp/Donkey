@testable import Donkey
import Foundation
import Testing

/// Sign-out is symmetric: a user-initiated sign-out revokes every Better Auth session for the user (so the
/// website and other devices sign out too), while a 401-driven sign-out is local cleanup only because the
/// server already revoked the session.
@MainActor
@Suite
struct DonkeyAuthCoordinatorSignOutTests {
    @Test
    func userInitiatedSignOutRevokesAllSessionsRemotely() async {
        let host = "revoke-test.example"
        let configuration = DonkeyAuthConfiguration(
            webBaseURL: URL(string: "https://\(host)")!,
            callbackScheme: "donkey"
        )
        let storage = Self.isolatedCookieStorage()
        Self.seedSessionCookie(in: storage, host: host)
        let revoker = RecordingRevoker()

        let coordinator = DonkeyAuthCoordinator(
            configuration: configuration,
            stateStore: StubAuthStateStore(),
            remoteSessionRevoker: revoker,
            cookieStorage: storage
        )

        coordinator.signOut(revokingRemoteSessions: true)
        await coordinator.pendingRemoteRevokeTask?.value

        #expect(revoker.calls.count == 1)
        #expect(revoker.calls.first?.webBaseURL == configuration.webBaseURL)
        #expect(revoker.calls.first?.cookies.contains { $0.name.contains("session_token") } == true)
        #expect(coordinator.isAuthenticated == false)
        // The local cookie jar is wiped as part of sign-out.
        #expect((storage.cookies(for: configuration.webBaseURL) ?? []).isEmpty)
    }

    @Test
    func sessionExpirySignOutDoesNotRevokeRemotely() async {
        let host = "norevoke-test.example"
        let configuration = DonkeyAuthConfiguration(
            webBaseURL: URL(string: "https://\(host)")!,
            callbackScheme: "donkey"
        )
        let storage = Self.isolatedCookieStorage()
        Self.seedSessionCookie(in: storage, host: host)
        let revoker = RecordingRevoker()

        let coordinator = DonkeyAuthCoordinator(
            configuration: configuration,
            stateStore: StubAuthStateStore(),
            remoteSessionRevoker: revoker,
            cookieStorage: storage
        )

        coordinator.signOut(revokingRemoteSessions: false)

        #expect(coordinator.pendingRemoteRevokeTask == nil)
        #expect(revoker.calls.isEmpty)
        #expect(coordinator.isAuthenticated == false)
    }

    // MARK: - Helpers

    private static func isolatedCookieStorage() -> HTTPCookieStorage {
        HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: "donkey-signout-test-\(UUID().uuidString)")
    }

    private static func seedSessionCookie(in storage: HTTPCookieStorage, host: String) {
        let cookie = HTTPCookie(properties: [
            .domain: host,
            .path: "/",
            .name: "better-auth.session_token",
            .value: "test-session-token",
        ])!
        storage.setCookie(cookie)
    }
}

/// Records the revoke calls the coordinator makes, in place of a real network round-trip.
private final class RecordingRevoker: DonkeyRemoteSessionRevoking, @unchecked Sendable {
    struct Call {
        let webBaseURL: URL
        let cookies: [HTTPCookie]
    }

    private let lock = NSLock()
    private var storedCalls: [Call] = []

    var calls: [Call] {
        lock.withLock { storedCalls }
    }

    func revokeAllSessions(webBaseURL: URL, cookies: [HTTPCookie]) async {
        lock.withLock { storedCalls.append(Call(webBaseURL: webBaseURL, cookies: cookies)) }
    }
}

/// In-memory auth state, so sign-out doesn't touch the shared user defaults.
private final class StubAuthStateStore: DonkeyAuthStateStoring, @unchecked Sendable {
    var session: DonkeyAuthSession?
    var hasEverSignedIn = false

    func loadSession() -> DonkeyAuthSession? { session }
    func saveSession(_ session: DonkeyAuthSession) { self.session = session }
    func clearSession() { session = nil }
    func loadPendingState() -> String? { nil }
    func savePendingState(_ state: String) {}
    func clearPendingState() {}
    func loadHasEverSignedIn() -> Bool { hasEverSignedIn }
    func markHasEverSignedIn() { hasEverSignedIn = true }
}
