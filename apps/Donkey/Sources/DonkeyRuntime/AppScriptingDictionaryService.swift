import Foundation

/// One cached parse of an app's scripting dictionary, invalidated when the app updates.
public struct ScriptingDictionaryCacheRecord: Equatable, Sendable, Codable {
    public var appVersion: String
    public var sdefPath: String
    public var sdefModificationDate: Date?
    public var dictionary: ScriptingDictionary

    public init(appVersion: String, sdefPath: String, sdefModificationDate: Date?, dictionary: ScriptingDictionary) {
        self.appVersion = appVersion
        self.sdefPath = sdefPath
        self.sdefModificationDate = sdefModificationDate
        self.dictionary = dictionary
    }
}

/// JSON-per-app store under Application Support so a dictionary is parsed once per app version,
/// then served from disk. Same shape as `FileAppScriptabilityStore`.
public final class FileScriptingDictionaryStore: @unchecked Sendable {
    private let directoryURL: URL
    private let lock = NSLock()

    public init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL()
    }

    public func record(bundleIdentifier: String) -> ScriptingDictionaryCacheRecord? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL(bundleIdentifier: bundleIdentifier)) else { return nil }
        return try? JSONDecoder().decode(ScriptingDictionaryCacheRecord.self, from: data)
    }

    public func save(_ record: ScriptingDictionaryCacheRecord, bundleIdentifier: String) {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? data.write(to: fileURL(bundleIdentifier: bundleIdentifier), options: .atomic)
    }

    private func fileURL(bundleIdentifier: String) -> URL {
        let safeName = bundleIdentifier.replacingOccurrences(of: "/", with: "_")
        return directoryURL.appendingPathComponent("\(safeName).json", isDirectory: false)
    }

    private static func defaultDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("Donkey", isDirectory: true)
            .appendingPathComponent("scripting-dictionaries", isDirectory: true)
    }
}

/// Front door for "what can this app actually do via AppleScript": resolves the installed bundle,
/// short-circuits non-scriptable apps via the existing probe, parses + caches the sdef, and renders
/// the bounded digest that grounds script generation and the `app_commands` command.
public actor AppScriptingDictionaryService {
    public static let shared = AppScriptingDictionaryService()

    public struct Lookup: Equatable, Sendable {
        public var scriptability: AppScriptability
        public var dictionary: ScriptingDictionary?
        public var digest: String
        public var commandNames: [String]

        public init(
            scriptability: AppScriptability,
            dictionary: ScriptingDictionary? = nil,
            digest: String = "",
            commandNames: [String] = []
        ) {
            self.scriptability = scriptability
            self.dictionary = dictionary
            self.digest = digest
            self.commandNames = commandNames
        }
    }

    private let store: FileScriptingDictionaryStore
    private let probe: MacAppScriptabilityProbe
    private var memo: [String: Lookup] = [:]

    public init(
        store: FileScriptingDictionaryStore = FileScriptingDictionaryStore(),
        probe: MacAppScriptabilityProbe = MacAppScriptabilityProbe()
    ) {
        self.store = store
        self.probe = probe
    }

    public func lookup(appName: String?, bundleIdentifier: String?) -> Lookup {
        guard let bundleURL = probe.bundleURL(bundleIdentifier: bundleIdentifier, appName: appName) else {
            return Lookup(scriptability: .unknown)
        }
        let info = Bundle(url: bundleURL)?.infoDictionary
        let resolvedBundleID = (bundleIdentifier?.isEmpty == false ? bundleIdentifier : nil)
            ?? info?["CFBundleIdentifier"] as? String
            ?? ""
        let appVersion = (info?["CFBundleShortVersionString"] as? String)
            ?? (info?["CFBundleVersion"] as? String)
            ?? ""
        let resolvedName = (info?["CFBundleName"] as? String)
            ?? appName
            ?? bundleURL.deletingPathExtension().lastPathComponent

        let memoKey = "\(resolvedBundleID)|\(appVersion)"
        if let cached = memo[memoKey] { return cached }

        let scriptability = probe.scriptability(bundleIdentifier: resolvedBundleID, appName: resolvedName)
        guard scriptability != .notScriptable else {
            let lookup = Lookup(scriptability: .notScriptable)
            memo[memoKey] = lookup
            return lookup
        }

        guard let dictionary = loadDictionary(
            bundleURL: bundleURL,
            bundleIdentifier: resolvedBundleID,
            appName: resolvedName,
            appVersion: appVersion
        ) else {
            let lookup = Lookup(scriptability: scriptability)
            memo[memoKey] = lookup
            return lookup
        }

        let lookup = Lookup(
            scriptability: scriptability,
            dictionary: dictionary,
            digest: ScriptingDictionaryDigest.render(dictionary),
            commandNames: dictionary.commandNames
        )
        memo[memoKey] = lookup
        return lookup
    }

    /// Full detail for one suite, matched case-insensitively on the suite's declared name.
    public func suiteDigest(appName: String?, bundleIdentifier: String?, suiteName: String) -> String? {
        let lookup = lookup(appName: appName, bundleIdentifier: bundleIdentifier)
        guard let dictionary = lookup.dictionary else { return nil }
        let wanted = suiteName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let suite = dictionary.suites.first(where: { $0.name.lowercased() == wanted }) else { return nil }
        return ScriptingDictionaryDigest.render(suite: suite, of: dictionary)
    }

    private func loadDictionary(
        bundleURL: URL,
        bundleIdentifier: String,
        appName: String,
        appVersion: String
    ) -> ScriptingDictionary? {
        let sdefURL = ScriptingDefinitionLocator.sdefURL(forBundleAt: bundleURL)
        let sdefModificationDate = sdefURL.flatMap { url in
            try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        }

        if !bundleIdentifier.isEmpty,
           let cached = store.record(bundleIdentifier: bundleIdentifier),
           cached.appVersion == appVersion,
           cached.sdefPath == (sdefURL?.path ?? ""),
           cached.sdefModificationDate == sdefModificationDate {
            return cached.dictionary
        }

        var suites: [ScriptingSuite] = []
        if let sdefURL {
            suites = (try? ScriptingDictionaryParser.suites(contentsOf: sdefURL)) ?? []
        }
        if suites.isEmpty,
           let data = OpenScriptingSdefLoader.copySdefData(forBundleAt: bundleURL) {
            suites = (try? ScriptingDictionaryParser.suites(from: data)) ?? []
        }
        guard !suites.isEmpty else { return nil }

        let dictionary = ScriptingDictionary(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            appVersion: appVersion,
            suites: suites
        )
        if !bundleIdentifier.isEmpty {
            store.save(
                ScriptingDictionaryCacheRecord(
                    appVersion: appVersion,
                    sdefPath: sdefURL?.path ?? "",
                    sdefModificationDate: sdefModificationDate,
                    dictionary: dictionary
                ),
                bundleIdentifier: bundleIdentifier
            )
        }
        return dictionary
    }
}
