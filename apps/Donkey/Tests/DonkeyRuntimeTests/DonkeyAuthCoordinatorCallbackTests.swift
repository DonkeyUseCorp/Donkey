@testable import Donkey
import Foundation
import Testing

/// The donkey:// sign-in callback is delivered more than once in the common case: the handoff web page
/// auto-redirects to the scheme and also offers an "Open Donkey" button, and LSMultipleInstancesProhibited
/// routes every delivery to the one running instance. Handling must therefore be idempotent and monotonic —
/// the first delivery carries the sign-in forward, and any duplicate must not knock it back to the login CTA —
/// while a genuinely unverifiable callback still fails.
@MainActor
@Suite
struct DonkeyAuthCoordinatorCallbackTests {
    @Test
    func duplicateCallbackDoesNotDowngradeInFlightExchange() {
        let store = CallbackStateStore()
        store.pendingState = "STATE"
        let coordinator = makeCoordinator(store: store)

        // First delivery (the page's auto-redirect) advances into the session exchange.
        #expect(coordinator.handleCallbackURL(Self.callbackURL(state: "STATE", code: "CODE")))
        #expect(coordinator.phase == .exchangingSession)

        // Second delivery (the user also clicks "Open Donkey"). The pending state is already consumed, but the
        // duplicate must leave the in-flight exchange untouched rather than flip back to the login CTA.
        #expect(coordinator.handleCallbackURL(Self.callbackURL(state: "STATE", code: "CODE")))
        #expect(coordinator.phase == .exchangingSession)
    }

    @Test
    func duplicateCallbackDoesNotSignOutLiveSession() {
        let store = CallbackStateStore()
        store.session = Self.session
        let coordinator = makeCoordinator(store: store)
        #expect(coordinator.isAuthenticated)

        // A late duplicate callback arriving after sign-in completed must leave the live session intact.
        #expect(coordinator.handleCallbackURL(Self.callbackURL(state: "STATE", code: "CODE")))
        #expect(coordinator.isAuthenticated)
    }

    @Test
    func mismatchedStateWhileAwaitingCallbackStillFails() {
        let store = CallbackStateStore()
        store.pendingState = "EXPECTED"
        let coordinator = makeCoordinator(store: store)

        // A forged or stale state while a real callback is still pending is a true verification failure.
        #expect(coordinator.handleCallbackURL(Self.callbackURL(state: "FORGED", code: "CODE")))
        #expect(coordinator.phase == .failed("Sign-in could not be verified. Please try again."))
    }

    // MARK: - Helpers

    private static let session = DonkeyAuthSession(
        id: "session-id",
        provider: "google",
        authenticatedAt: Date(timeIntervalSince1970: 0)
    )

    private static func callbackURL(state: String, code: String) -> URL {
        URL(string: "donkey://auth/callback?state=\(state)&code=\(code)")!
    }

    private func makeCoordinator(store: CallbackStateStore) -> DonkeyAuthCoordinator {
        DonkeyAuthCoordinator(
            configuration: DonkeyAuthConfiguration(
                webBaseURL: URL(string: "https://callback-test.example")!,
                callbackScheme: "donkey"
            ),
            stateStore: store,
            nativeSessionExchanger: HangingExchanger()
        )
    }
}

/// Suspends indefinitely so the coordinator stays in `.exchangingSession` for the test's lifetime, letting the
/// in-flight phase be observed without racing a completed exchange.
private struct HangingExchanger: DonkeyNativeSessionExchanging {
    func exchange(code: String, webBaseURL: URL) async throws -> DonkeyNativeCookieSession {
        try await Task.sleep(nanoseconds: .max)
        return DonkeyNativeCookieSession(sessionID: "unused")
    }
}

/// In-memory auth state that can carry both a pending state token and a session, so callback handling can be
/// exercised without touching the shared user defaults.
private final class CallbackStateStore: DonkeyAuthStateStoring, @unchecked Sendable {
    var session: DonkeyAuthSession?
    var pendingState: String?
    var hasEverSignedIn = false

    func loadSession() -> DonkeyAuthSession? { session }
    func saveSession(_ session: DonkeyAuthSession) { self.session = session }
    func clearSession() { session = nil }
    func loadPendingState() -> String? { pendingState }
    func savePendingState(_ state: String) { pendingState = state }
    func clearPendingState() { pendingState = nil }
    func loadHasEverSignedIn() -> Bool { hasEverSignedIn }
    func markHasEverSignedIn() { hasEverSignedIn = true }
}
