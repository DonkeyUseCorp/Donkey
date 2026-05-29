import Foundation

/// What the harness has learned about one app on THIS machine: the bundle probe plus how
/// AppleScript attempts have actually turned out here.
public struct AppScriptabilityObservation: Equatable, Sendable, Codable {
    public var bundleIdentifier: String
    public var probed: AppScriptability
    public var appleScriptSuccesses: Int
    public var appleScriptFailures: Int

    public init(
        bundleIdentifier: String,
        probed: AppScriptability,
        appleScriptSuccesses: Int = 0,
        appleScriptFailures: Int = 0
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.probed = probed
        self.appleScriptSuccesses = appleScriptSuccesses
        self.appleScriptFailures = appleScriptFailures
    }
}

/// Resolves scriptability from learned evidence: actual runtime outcomes on this machine override
/// the static bundle probe. Any confirmed AppleScript success means the app works here; repeated
/// failures with no success mean it does not (regardless of what the bundle declared).
public enum AppScriptabilityResolver {
    public static let failureThreshold = 2

    public static func resolve(_ observation: AppScriptabilityObservation) -> AppScriptability {
        if observation.appleScriptSuccesses > 0 {
            return .scriptable
        }
        if observation.appleScriptFailures >= failureThreshold {
            return .notScriptable
        }
        return observation.probed
    }
}

/// Persistent per-machine record of learned app capabilities.
public protocol AppScriptabilityStore: Sendable {
    func observation(bundleIdentifier: String) -> AppScriptabilityObservation?
    func record(_ observation: AppScriptabilityObservation)
}

public final class InMemoryAppScriptabilityStore: AppScriptabilityStore, @unchecked Sendable {
    private var records: [String: AppScriptabilityObservation] = [:]
    private let lock = NSLock()

    public init() {}

    public func observation(bundleIdentifier: String) -> AppScriptabilityObservation? {
        lock.lock(); defer { lock.unlock() }
        return records[bundleIdentifier]
    }

    public func record(_ observation: AppScriptabilityObservation) {
        lock.lock(); defer { lock.unlock() }
        records[observation.bundleIdentifier] = observation
    }
}

/// JSON-backed store under Application Support, so learning persists across runs on this machine.
public final class FileAppScriptabilityStore: AppScriptabilityStore, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var cache: [String: AppScriptabilityObservation]

    public init(url: URL? = nil) {
        let resolved = url ?? Self.defaultURL()
        self.url = resolved
        self.cache = Self.load(resolved)
    }

    public func observation(bundleIdentifier: String) -> AppScriptabilityObservation? {
        lock.lock(); defer { lock.unlock() }
        return cache[bundleIdentifier]
    }

    public func record(_ observation: AppScriptabilityObservation) {
        lock.lock(); defer { lock.unlock() }
        cache[observation.bundleIdentifier] = observation
        persistLocked()
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    private static func load(_ url: URL) -> [String: AppScriptabilityObservation] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: AppScriptabilityObservation].self, from: data)
        else {
            return [:]
        }
        return decoded
    }

    private static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("Donkey", isDirectory: true)
            .appendingPathComponent("app-scriptability.json", isDirectory: false)
    }
}

/// Combines the bundle probe with the learning store: probes an app the first time it is seen on
/// this machine (and remembers it), then refines the answer from real AppleScript outcomes.
public final class AppCapabilityService: @unchecked Sendable {
    public typealias ScriptabilityProbe = @Sendable (_ bundleIdentifier: String?, _ appName: String?) -> AppScriptability

    private let store: AppScriptabilityStore
    private let probe: ScriptabilityProbe

    public init(
        store: AppScriptabilityStore = FileAppScriptabilityStore(),
        probe: @escaping ScriptabilityProbe = { MacAppScriptabilityProbe().scriptability(bundleIdentifier: $0, appName: $1) }
    ) {
        self.store = store
        self.probe = probe
    }

    /// Best current answer for the app, learned from this machine.
    public func scriptability(bundleIdentifier: String?, appName: String? = nil) -> AppScriptability {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return probe(bundleIdentifier, appName)
        }
        let observation = store.observation(bundleIdentifier: bundleIdentifier) ?? {
            // First encounter on this machine: probe the installed bundle and remember it.
            let fresh = AppScriptabilityObservation(
                bundleIdentifier: bundleIdentifier,
                probed: probe(bundleIdentifier, appName)
            )
            store.record(fresh)
            return fresh
        }()
        return AppScriptabilityResolver.resolve(observation)
    }

    /// Learn from an actual AppleScript attempt on this machine.
    public func recordAppleScriptOutcome(bundleIdentifier: String?, appName: String? = nil, succeeded: Bool) {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return }
        var observation = store.observation(bundleIdentifier: bundleIdentifier)
            ?? AppScriptabilityObservation(bundleIdentifier: bundleIdentifier, probed: probe(bundleIdentifier, appName))
        if succeeded {
            observation.appleScriptSuccesses += 1
        } else {
            observation.appleScriptFailures += 1
        }
        store.record(observation)
    }
}
