import AppKit
import Foundation

struct DonkeyAuthSession: Codable, Equatable {
    var id: String
    var provider: String
    var authenticatedAt: Date
    var remoteSessionID: String? = nil
    var userEmail: String? = nil
    var userName: String? = nil
}

enum DonkeyAuthPhase: Equatable {
    case signedOut
    case openingBrowser
    case waitingForCallback
    case exchangingSession
    case signedIn(DonkeyAuthSession)
    case failed(String)

    var isSignedIn: Bool {
        if case .signedIn = self {
            return true
        }
        return false
    }
}

struct DonkeyAuthConfiguration: Equatable {
    var webBaseURL: URL
    var callbackScheme: String

    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> DonkeyAuthConfiguration {
        let webBaseURL = Self.configuredURL(
            environment: environment,
            bundle: bundle
        ) ?? URL(string: "http://localhost:3000")!
        let callbackScheme = Self.configuredValue(
            environmentKey: "DONKEY_AUTH_CALLBACK_SCHEME",
            bundleKey: "DonkeyAuthCallbackScheme",
            environment: environment,
            bundle: bundle
        ) ?? "donkey"

        return DonkeyAuthConfiguration(
            webBaseURL: webBaseURL,
            callbackScheme: callbackScheme
        )
    }

    private static func configuredURL(
        environment: [String: String],
        bundle: Bundle
    ) -> URL? {
        let configuredValue = configuredValue(
            environmentKey: "DONKEY_WEB_BASE_URL",
            bundleKey: "DonkeyWebBaseURL",
            environment: environment,
            bundle: bundle
        ) ?? environment["BETTER_AUTH_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let configuredValue,
              !configuredValue.isEmpty else {
            return nil
        }

        return URL(string: configuredValue)
    }

    private static func configuredValue(
        environmentKey: String,
        bundleKey: String,
        environment: [String: String],
        bundle: Bundle
    ) -> String? {
        if let environmentValue = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !environmentValue.isEmpty {
            return environmentValue
        }

        let bundleValue = bundle.object(forInfoDictionaryKey: bundleKey) as? String
        let trimmedBundleValue = bundleValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedBundleValue?.isEmpty == false ? trimmedBundleValue : nil
    }
}

@MainActor
final class DonkeyAuthCoordinator: ObservableObject {
    @Published private(set) var phase: DonkeyAuthPhase

    var authenticationCompleted: ((DonkeyAuthSession) -> Void)?

    private let configuration: DonkeyAuthConfiguration
    private let stateStore: DonkeyAuthStateStoring
    private let nativeSessionExchanger: any DonkeyNativeSessionExchanging
    private let remoteSessionRevoker: any DonkeyRemoteSessionRevoking
    private let cookieStorage: HTTPCookieStorage

    /// The in-flight best-effort remote revoke spawned by a user-initiated sign-out. Exposed so it can
    /// be awaited in tests; production code never reads it.
    private(set) var pendingRemoteRevokeTask: Task<Void, Never>?

    init(
        configuration: DonkeyAuthConfiguration = .current(),
        stateStore: DonkeyAuthStateStoring = DonkeyAuthStateStore(),
        nativeSessionExchanger: any DonkeyNativeSessionExchanging = DonkeyNativeSessionCookieExchanger(),
        remoteSessionRevoker: any DonkeyRemoteSessionRevoking = DonkeyRemoteSessionRevoker(),
        cookieStorage: HTTPCookieStorage = .shared
    ) {
        self.configuration = configuration
        self.stateStore = stateStore
        self.nativeSessionExchanger = nativeSessionExchanger
        self.remoteSessionRevoker = remoteSessionRevoker
        self.cookieStorage = cookieStorage

        if let session = stateStore.loadSession() {
            stateStore.markHasEverSignedIn()
            phase = .signedIn(session)
        } else {
            phase = .signedOut
        }
    }

    var isAuthenticated: Bool {
        phase.isSignedIn
    }

    /// Whether this Mac has completed sign-in at least once. Distinguishes a first install (never
    /// signed in → show the welcome window) from an expired session (signed in before → drive the
    /// re-auth through the notch login).
    var hasEverSignedIn: Bool {
        stateStore.loadHasEverSignedIn()
    }

    func beginGoogleSignIn() {
        let state = Self.makeStateToken()

        guard let signInURL = signInURL(state: state) else {
            phase = .failed("Sign-in could not be configured.")
            return
        }

        stateStore.savePendingState(state)
        phase = .openingBrowser

        guard NSWorkspace.shared.open(signInURL) else {
            stateStore.clearPendingState()
            phase = .failed("The browser could not be opened.")
            return
        }

        phase = .waitingForCallback
    }

    @discardableResult
    func handleCallbackURL(_ url: URL) -> Bool {
        guard isAuthCallbackURL(url) else {
            return false
        }

        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let returnedState = Self.queryValue(named: "state", in: queryItems),
              let expectedState = stateStore.loadPendingState(),
              returnedState == expectedState else {
            phase = .failed("Sign-in could not be verified. Please try again.")
            return true
        }

        stateStore.clearPendingState()

        if let error = Self.queryValue(named: "error", in: queryItems), !error.isEmpty {
            phase = .failed("Google sign-in did not finish. Please try again.")
            return true
        }

        guard let code = Self.queryValue(named: "code", in: queryItems),
              !code.isEmpty else {
            phase = .failed("Google sign-in did not return a Mac session code.")
            return true
        }

        phase = .exchangingSession
        exchangeNativeSession(code: code)
        return true
    }

    private func exchangeNativeSession(code: String) {
        let webBaseURL = configuration.webBaseURL
        let nativeSessionExchanger = nativeSessionExchanger
        Task { [weak self] in
            do {
                let nativeSession = try await nativeSessionExchanger.exchange(
                    code: code,
                    webBaseURL: webBaseURL
                )
                await MainActor.run {
                    self?.completeNativeSessionExchange(nativeSession)
                }
            } catch {
                await MainActor.run {
                    self?.phase = .failed("Mac session could not be created. Please try again.")
                }
            }
        }
    }

    private func completeNativeSessionExchange(_ nativeSession: DonkeyNativeCookieSession) {
        let session = DonkeyAuthSession(
            id: nativeSession.sessionID,
            provider: "google",
            authenticatedAt: Date(),
            remoteSessionID: nativeSession.sessionID,
            userEmail: nativeSession.userEmail,
            userName: nativeSession.userName
        )
        stateStore.markHasEverSignedIn()
        stateStore.saveSession(session)
        phase = .signedIn(session)
        authenticationCompleted?(session)
    }

    func clearFailedState() {
        guard case .failed = phase else { return }
        phase = stateStore.loadSession().map(DonkeyAuthPhase.signedIn) ?? .signedOut
    }

    /// Returns a stalled or failed sign-in to the ready (signed-out) state so the sign-in button is
    /// enabled and its status line is clear when the onboarding card is (re)shown. The common trigger is
    /// the user dismissing the onboarding card on "Continue with Google", then abandoning the browser:
    /// without this, `phase` would sit at `.waitingForCallback` forever and the button would stay disabled.
    /// A live session or an in-progress exchange is left untouched, and the pending state token is kept so a
    /// late but legitimate callback can still complete.
    func resetSignInIfStalled() {
        switch phase {
        case .openingBrowser, .waitingForCallback, .failed:
            phase = .signedOut
        case .signedOut, .exchangingSession, .signedIn:
            break
        }
    }

    /// Drops the local session and its native session cookie, returning to the signed-out state. Callers
    /// should then surface the login flow again.
    ///
    /// When `revokingRemoteSessions` is true (a user-initiated sign-out), it also fires a best-effort call
    /// to revoke every Better Auth session for this user, so the browser — and any other device — signs out
    /// too. The 401-driven path passes false: the server already revoked the session, so this is only local
    /// cleanup. Local cleanup always runs, even if the revoke call can't be made (e.g. offline).
    func signOut(revokingRemoteSessions: Bool = true) {
        // Snapshot the session cookie before clearing local state, so the best-effort remote revoke can
        // authenticate even though the cookie jar is wiped immediately below.
        let cookies = revokingRemoteSessions ? sessionCookies() : []
        if revokingRemoteSessions, !cookies.isEmpty {
            let revoker = remoteSessionRevoker
            let webBaseURL = configuration.webBaseURL
            pendingRemoteRevokeTask = Task {
                await revoker.revokeAllSessions(webBaseURL: webBaseURL, cookies: cookies)
            }
        } else {
            pendingRemoteRevokeTask = nil
        }

        stateStore.clearSession()
        stateStore.clearPendingState()
        clearSessionCookies()
        phase = .signedOut
    }

    private func sessionCookies() -> [HTTPCookie] {
        cookieStorage.cookies(for: configuration.webBaseURL) ?? []
    }

    private func clearSessionCookies() {
        for cookie in sessionCookies() {
            cookieStorage.deleteCookie(cookie)
        }
    }

    private func signInURL(state: String) -> URL? {
        var components = URLComponents(
            url: configuration.webBaseURL,
            resolvingAgainstBaseURL: false
        )
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.path = "/" + [basePath, "mac-auth"]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components?.queryItems = [
            URLQueryItem(name: "state", value: state)
        ]
        return components?.url
    }

    private func isAuthCallbackURL(_ url: URL) -> Bool {
        url.scheme == configuration.callbackScheme &&
            url.host == "auth" &&
            url.path == "/callback"
    }

    private static func makeStateToken() -> String {
        "\(UUID().uuidString)-\(UUID().uuidString)"
    }

    private static func queryValue(
        named name: String,
        in queryItems: [URLQueryItem]
    ) -> String? {
        queryItems.first { $0.name == name }?.value
    }
}

protocol DonkeyAuthStateStoring {
    func loadSession() -> DonkeyAuthSession?
    func saveSession(_ session: DonkeyAuthSession)
    func clearSession()
    func loadPendingState() -> String?
    func savePendingState(_ state: String)
    func clearPendingState()
    func loadHasEverSignedIn() -> Bool
    func markHasEverSignedIn()
}

struct DonkeyAuthStateStore: DonkeyAuthStateStoring {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadSession() -> DonkeyAuthSession? {
        guard let data = defaults.data(forKey: Keys.session) else {
            return nil
        }

        return try? JSONDecoder().decode(DonkeyAuthSession.self, from: data)
    }

    func saveSession(_ session: DonkeyAuthSession) {
        guard let data = try? JSONEncoder().encode(session) else {
            return
        }

        defaults.set(data, forKey: Keys.session)
    }

    func clearSession() {
        defaults.removeObject(forKey: Keys.session)
    }

    func loadPendingState() -> String? {
        defaults.string(forKey: Keys.pendingState)
    }

    func savePendingState(_ state: String) {
        defaults.set(state, forKey: Keys.pendingState)
    }

    func clearPendingState() {
        defaults.removeObject(forKey: Keys.pendingState)
    }

    func loadHasEverSignedIn() -> Bool {
        defaults.bool(forKey: Keys.hasEverSignedIn)
    }

    func markHasEverSignedIn() {
        defaults.set(true, forKey: Keys.hasEverSignedIn)
    }

    private enum Keys {
        static let session = "donkey.auth.session"
        static let pendingState = "donkey.auth.pendingState"
        static let hasEverSignedIn = "donkey.auth.hasEverSignedIn"
    }
}
