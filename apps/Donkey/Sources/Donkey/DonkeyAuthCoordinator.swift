import AppKit
import Foundation

struct DonkeyAuthSession: Codable, Equatable {
    var id: String
    var provider: String
    var authenticatedAt: Date
}

enum DonkeyAuthPhase: Equatable {
    case signedOut
    case openingBrowser
    case waitingForCallback
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

    init(
        configuration: DonkeyAuthConfiguration = .current(),
        stateStore: DonkeyAuthStateStoring = DonkeyAuthStateStore()
    ) {
        self.configuration = configuration
        self.stateStore = stateStore

        if let session = stateStore.loadSession() {
            phase = .signedIn(session)
        } else {
            phase = .signedOut
        }
    }

    var isAuthenticated: Bool {
        phase.isSignedIn
    }

    func beginGoogleSignIn() {
        let state = Self.makeStateToken()

        guard let callbackURL = callbackURL(state: state),
              let signInURL = signInURL(callbackURL: callbackURL) else {
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

        let session = DonkeyAuthSession(
            id: UUID().uuidString,
            provider: "google",
            authenticatedAt: Date()
        )
        stateStore.saveSession(session)
        phase = .signedIn(session)
        authenticationCompleted?(session)
        return true
    }

    func clearFailedState() {
        guard case .failed = phase else { return }
        phase = stateStore.loadSession().map(DonkeyAuthPhase.signedIn) ?? .signedOut
    }

    private func callbackURL(state: String) -> URL? {
        var components = URLComponents()
        components.scheme = configuration.callbackScheme
        components.host = "auth"
        components.path = "/callback"
        components.queryItems = [
            URLQueryItem(name: "state", value: state)
        ]
        return components.url
    }

    private func signInURL(callbackURL: URL) -> URL? {
        var components = URLComponents(
            url: configuration.webBaseURL,
            resolvingAgainstBaseURL: false
        )
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.path = "/" + [basePath, "mac-auth"]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components?.queryItems = [
            URLQueryItem(name: "callbackURL", value: callbackURL.absoluteString),
            URLQueryItem(name: "errorCallbackURL", value: callbackURL.absoluteString)
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
    func loadPendingState() -> String?
    func savePendingState(_ state: String)
    func clearPendingState()
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

    func loadPendingState() -> String? {
        defaults.string(forKey: Keys.pendingState)
    }

    func savePendingState(_ state: String) {
        defaults.set(state, forKey: Keys.pendingState)
    }

    func clearPendingState() {
        defaults.removeObject(forKey: Keys.pendingState)
    }

    private enum Keys {
        static let session = "donkey.auth.session"
        static let pendingState = "donkey.auth.pendingState"
    }
}
