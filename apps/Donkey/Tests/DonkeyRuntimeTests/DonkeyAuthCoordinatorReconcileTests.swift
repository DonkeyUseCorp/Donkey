@testable import Donkey
import Foundation
import Testing

/// The notch's login state is driven by the in-memory `phase`, which syncs with the durable session only at
/// init. When the donkey:// callback is serviced by a different app instance sharing this UserDefaults domain,
/// the session lands on disk while this instance stays signed-out. `reconcileWithPersistedSession()` heals that
/// on the next activation by promoting signed-out → signed-in from the store, without clobbering any other phase.
@MainActor
@Suite
struct DonkeyAuthCoordinatorReconcileTests {
    @Test
    func reconcilePromotesSignedOutToSignedInWhenSessionAppearsOnDisk() {
        let store = MutableAuthStateStore()
        let coordinator = makeCoordinator(store: store)
        #expect(coordinator.isAuthenticated == false)

        // Another instance mints the session in the shared store after this coordinator already came up
        // signed-out.
        store.session = Self.session

        coordinator.reconcileWithPersistedSession()

        #expect(coordinator.isAuthenticated)
    }

    @Test
    func reconcileIsNoOpWhenNoSessionOnDisk() {
        let coordinator = makeCoordinator(store: MutableAuthStateStore())

        coordinator.reconcileWithPersistedSession()

        #expect(coordinator.isAuthenticated == false)
    }

    @Test
    func reconcileDoesNotClobberLiveSessionWhenStoreIsCleared() {
        let store = MutableAuthStateStore()
        store.session = Self.session
        let coordinator = makeCoordinator(store: store)
        #expect(coordinator.isAuthenticated)

        // A stale read or a cross-instance clear must not sign a live session out on activation.
        store.session = nil
        coordinator.reconcileWithPersistedSession()

        #expect(coordinator.isAuthenticated)
    }

    // MARK: - Helpers

    private static let session = DonkeyAuthSession(
        id: "session-id",
        provider: "google",
        authenticatedAt: Date(timeIntervalSince1970: 0)
    )

    private func makeCoordinator(store: MutableAuthStateStore) -> DonkeyAuthCoordinator {
        DonkeyAuthCoordinator(
            configuration: DonkeyAuthConfiguration(
                webBaseURL: URL(string: "https://reconcile-test.example")!,
                callbackScheme: "donkey"
            ),
            stateStore: store
        )
    }
}

/// In-memory auth state whose session can be mutated between calls to simulate another instance writing the
/// shared store.
private final class MutableAuthStateStore: DonkeyAuthStateStoring, @unchecked Sendable {
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
