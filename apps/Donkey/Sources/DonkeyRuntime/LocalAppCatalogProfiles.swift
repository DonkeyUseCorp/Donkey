import DonkeyContracts
import Foundation

public struct LocalApplicationCatalogCandidate: Codable, Equatable, Sendable {
    public var appName: String
    public var bundleIdentifier: String?
    public var path: String?
    public var metadata: [String: String]

    public init(
        appName: String,
        bundleIdentifier: String? = nil,
        path: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier?.nilIfEmpty
        self.path = path?.nilIfEmpty
        self.metadata = metadata
    }

    public var catalogID: String {
        LocalAppFinderProfileStore.catalogID(
            appName: appName,
            bundleIdentifier: bundleIdentifier
        )
    }
}

public protocol LocalApplicationCatalogScanning: Sendable {
    func installedApplications() -> [LocalApplicationCatalogCandidate]
}

public struct MacInstalledApplicationCatalogScanner: LocalApplicationCatalogScanning {
    public init() {}

    public func installedApplications() -> [LocalApplicationCatalogCandidate] {
        MacLocalAppAvailabilityProvider.installedApplications()
    }
}

public struct LocalAppFinderProfileCatalog: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var entries: [LocalAppFinderCatalogEntry]
    public var aliases: [String: String]

    public init(
        schemaVersion: Int = 1,
        entries: [LocalAppFinderCatalogEntry],
        aliases: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.entries = entries
        self.aliases = aliases
    }
}

public struct LocalAppCatalogProfileGenerationResult: Equatable, Sendable {
    public var generatedEntries: [LocalAppFinderCatalogEntry]
    public var attemptedApplicationIDs: Set<String>
    public var metadata: [String: String]

    public init(
        generatedEntries: [LocalAppFinderCatalogEntry],
        attemptedApplicationIDs: Set<String>,
        metadata: [String: String] = [:]
    ) {
        self.generatedEntries = generatedEntries
        self.attemptedApplicationIDs = attemptedApplicationIDs
        self.metadata = metadata
    }
}

public protocol LocalAppCatalogProfileGenerating: Sendable {
    func generateProfiles(
        for applications: [LocalApplicationCatalogCandidate],
        existingProfiles: [LocalAppFinderCatalogEntry],
        sourceTraceID: String
    ) async -> LocalAppCatalogProfileGenerationResult
}

public struct NoOpLocalAppCatalogProfileGenerator: LocalAppCatalogProfileGenerating {
    public init() {}

    public func generateProfiles(
        for applications: [LocalApplicationCatalogCandidate],
        existingProfiles _: [LocalAppFinderCatalogEntry],
        sourceTraceID _: String
    ) async -> LocalAppCatalogProfileGenerationResult {
        LocalAppCatalogProfileGenerationResult(
            generatedEntries: [],
            attemptedApplicationIDs: [],
            metadata: [
                "generator": "noop",
                "skippedApplicationCount": String(applications.count)
            ]
        )
    }
}

public struct LocalAppCatalogRefreshState: Codable, Equatable, Sendable {
    public var lastRefreshAt: Date?
    public var seenApplicationIDs: [String]
    public var metadata: [String: String]

    public init(
        lastRefreshAt: Date? = nil,
        seenApplicationIDs: [String] = [],
        metadata: [String: String] = [:]
    ) {
        self.lastRefreshAt = lastRefreshAt
        self.seenApplicationIDs = seenApplicationIDs
        self.metadata = metadata
    }
}

public struct LocalAppCatalogRefreshResult: Equatable, Sendable {
    public var status: String
    public var installedApplicationCount: Int
    public var newApplicationCount: Int
    public var generatedProfileCount: Int
    public var snapshotEntryCount: Int
    public var metadata: [String: String]

    public init(
        status: String,
        installedApplicationCount: Int,
        newApplicationCount: Int,
        generatedProfileCount: Int,
        snapshotEntryCount: Int,
        metadata: [String: String] = [:]
    ) {
        self.status = status
        self.installedApplicationCount = installedApplicationCount
        self.newApplicationCount = newApplicationCount
        self.generatedProfileCount = generatedProfileCount
        self.snapshotEntryCount = snapshotEntryCount
        self.metadata = metadata
    }
}

public struct LocalAppFinderProfileStore: Sendable {
    public var seedCatalogURL: URL?
    public var generatedCatalogURL: URL
    public var resolvedCatalogURL: URL
    public var refreshStateURL: URL
    public var decoder: JSONDecoder
    public var encoder: JSONEncoder

    public init(
        seedCatalogURL: URL?,
        generatedCatalogURL: URL,
        resolvedCatalogURL: URL,
        refreshStateURL: URL,
        decoder: JSONDecoder = JSONDecoder(),
        encoder: JSONEncoder = LocalAppFinderProfileStore.defaultEncoder()
    ) {
        self.seedCatalogURL = seedCatalogURL
        self.generatedCatalogURL = generatedCatalogURL
        self.resolvedCatalogURL = resolvedCatalogURL
        self.refreshStateURL = refreshStateURL
        self.decoder = decoder
        self.encoder = encoder
    }

    public static var defaultDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Donkey", isDirectory: true)
            .appendingPathComponent("AppCatalog", isDirectory: true)
    }

    public static var defaultStore: LocalAppFinderProfileStore {
        let directory = defaultDirectoryURL
        return LocalAppFinderProfileStore(
            seedCatalogURL: DonkeyResourceBundle.runtime?.url(
                forResource: "local-app-finder-profiles",
                withExtension: "json"
            ),
            generatedCatalogURL: directory.appendingPathComponent(
                "local-app-finder-profiles.generated.json",
                isDirectory: false
            ),
            resolvedCatalogURL: directory.appendingPathComponent(
                "local-app-finder-catalog.snapshot.json",
                isDirectory: false
            ),
            refreshStateURL: directory.appendingPathComponent(
                "local-app-catalog-refresh-state.json",
                isDirectory: false
            )
        )
    }

    public static func catalogID(appName: String, bundleIdentifier: String?) -> String {
        if let bundleIdentifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }
        return "app:\(LocalAppLookup.normalized(appName))"
    }

    public func profileEntries() -> [LocalAppFinderCatalogEntry] {
        mergedProfileCatalog().entries
    }

    public func resolvedCatalogEntries() -> [LocalAppFinderCatalogEntry] {
        loadCatalog(from: resolvedCatalogURL).entries
            .map { sanitizedEntry($0) }
            .sorted(by: Self.isOrderedBefore)
    }

    public func knownProfileIDs() -> Set<String> {
        let catalog = mergedProfileCatalog()
        return Set(catalog.entries.flatMap { entry in
            [
                entry.appID,
                entry.bundleIdentifier ?? "",
                Self.catalogID(appName: entry.appName, bundleIdentifier: entry.bundleIdentifier)
            ].filter { !$0.isEmpty }
        }).union(catalog.aliases.values)
    }

    public func profile(
        appName: String,
        bundleIdentifier: String?
    ) -> LocalAppFinderCatalogEntry? {
        let catalog = mergedProfileCatalog()
        let entries = catalog.entries
        if let bundleIdentifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleIdentifier.isEmpty,
           let entry = entries.first(where: {
            $0.bundleIdentifier == bundleIdentifier || $0.appID == bundleIdentifier
           }) {
            return entry
        }

        let normalizedName = LocalAppLookup.normalized(appName)
        if let aliasTarget = catalog.aliases[normalizedName],
           let entry = Self.entry(matching: aliasTarget, in: entries) {
            return entry
        }

        return entries.first {
            LocalAppLookup.normalized($0.appName) == normalizedName
        }
    }

    public func entry(
        appName: String,
        bundleIdentifier: String?,
        path: String? = nil
    ) -> LocalAppFinderCatalogEntry {
        let candidate = LocalApplicationCatalogCandidate(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            path: path
        )
        return entry(for: candidate)
    }

    public func entry(for candidate: LocalApplicationCatalogCandidate) -> LocalAppFinderCatalogEntry {
        let baseMetadata = baseMetadata(path: candidate.path)
        let appID = candidate.catalogID
        if let profile = profile(
            appName: candidate.appName,
            bundleIdentifier: candidate.bundleIdentifier
        ) {
            let metadata = profile.metadata.merging(baseMetadata) { current, _ in current }
            return LocalAppFinderCatalogEntry(
                appID: appID,
                appName: candidate.appName,
                bundleIdentifier: candidate.bundleIdentifier,
                description: profile.description,
                supportStatus: profile.supportStatus,
                capabilities: profile.capabilities,
                denyReason: profile.denyReason,
                metadata: metadata
            )
        }

        return LocalAppFinderCatalogEntry(
            appID: appID,
            appName: candidate.appName,
            bundleIdentifier: candidate.bundleIdentifier,
            description: "Installed app; no declared executable workflow.",
            supportStatus: .candidate,
            capabilities: [],
            metadata: baseMetadata
        )
    }

    public func inferredAppName(from bundleIdentifier: String) -> String {
        if let profile = profile(appName: "", bundleIdentifier: bundleIdentifier) {
            return profile.appName
        }
        return LocalAppLookup.titleCased(
            bundleIdentifier.split(separator: ".").last.map(String.init) ?? bundleIdentifier
        )
    }

    public func upsertGeneratedProfiles(_ entries: [LocalAppFinderCatalogEntry]) throws {
        guard !entries.isEmpty else { return }

        let seedCatalog = loadCatalog(from: seedCatalogURL)
        var generatedCatalog = loadCatalog(from: generatedCatalogURL)
        var generatedByID = Dictionary(
            uniqueKeysWithValues: generatedCatalog.entries.map { entry in
                (entry.appID, entry)
            }
        )
        let seedIDs = Set(seedCatalog.entries.flatMap { entry in
            [entry.appID, entry.bundleIdentifier ?? ""]
        })

        for entry in entries {
            let sanitized = sanitizedEntry(entry)
            guard !seedIDs.contains(sanitized.appID),
                  !seedIDs.contains(sanitized.bundleIdentifier ?? "")
            else {
                continue
            }
            generatedByID[sanitized.appID] = sanitized
        }

        generatedCatalog.entries = generatedByID.values.sorted(by: Self.isOrderedBefore)
        try writeCatalog(generatedCatalog, to: generatedCatalogURL)
    }

    public func writeResolvedCatalogEntries(_ entries: [LocalAppFinderCatalogEntry]) throws {
        try writeCatalog(
            LocalAppFinderProfileCatalog(
                entries: entries
                    .map { sanitizedEntry($0) }
                    .sorted(by: Self.isOrderedBefore)
            ),
            to: resolvedCatalogURL
        )
    }

    public func loadRefreshState() -> LocalAppCatalogRefreshState {
        guard let data = try? Data(contentsOf: refreshStateURL),
              let state = try? decoder.decode(LocalAppCatalogRefreshState.self, from: data)
        else {
            return LocalAppCatalogRefreshState()
        }
        return state
    }

    public func writeRefreshState(_ state: LocalAppCatalogRefreshState) throws {
        try write(state, to: refreshStateURL)
    }

    private func mergedProfileCatalog() -> LocalAppFinderProfileCatalog {
        let seedCatalog = normalizedCatalog(loadCatalog(from: seedCatalogURL))
        let generatedCatalog = normalizedCatalog(loadCatalog(from: generatedCatalogURL))
        var entriesByID = Dictionary(
            uniqueKeysWithValues: seedCatalog.entries.map { entry in
                (entry.appID, entry)
            }
        )
        let seedBundleIDs = Set(seedCatalog.entries.compactMap(\.bundleIdentifier))
        for entry in generatedCatalog.entries {
            guard entriesByID[entry.appID] == nil,
                  !seedBundleIDs.contains(entry.bundleIdentifier ?? "")
            else {
                continue
            }
            entriesByID[entry.appID] = entry
        }

        return LocalAppFinderProfileCatalog(
            entries: entriesByID.values.sorted(by: Self.isOrderedBefore),
            aliases: seedCatalog.aliases.merging(generatedCatalog.aliases) { seed, _ in seed }
        )
    }

    private func normalizedCatalog(_ catalog: LocalAppFinderProfileCatalog) -> LocalAppFinderProfileCatalog {
        LocalAppFinderProfileCatalog(
            schemaVersion: catalog.schemaVersion,
            entries: catalog.entries.map { sanitizedEntry($0) },
            aliases: catalog.aliases.reduce(into: [:]) { result, pair in
                result[LocalAppLookup.normalized(pair.key)] = pair.value
            }
        )
    }

    private func loadCatalog(from url: URL?) -> LocalAppFinderProfileCatalog {
        guard let url,
              let data = try? Data(contentsOf: url),
              let catalog = try? decoder.decode(LocalAppFinderProfileCatalog.self, from: data)
        else {
            return LocalAppFinderProfileCatalog(entries: [])
        }
        return catalog
    }

    private func writeCatalog(_ catalog: LocalAppFinderProfileCatalog, to url: URL) throws {
        try write(catalog, to: url)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func sanitizedEntry(_ entry: LocalAppFinderCatalogEntry) -> LocalAppFinderCatalogEntry {
        let appName = entry.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeAppName = appName.isEmpty ? "Unknown App" : appName
        let bundleIdentifier = entry.bundleIdentifier?.nilIfEmpty
        let appID = Self.catalogID(appName: safeAppName, bundleIdentifier: bundleIdentifier)
        let supportStatus = sanitizedSupportStatus(entry)
        let capabilities = supportStatus == .supported || supportStatus == .candidate
            ? entry.capabilities.compactMap(sanitizedCapability)
            : []

        return LocalAppFinderCatalogEntry(
            appID: appID,
            appName: safeAppName,
            bundleIdentifier: bundleIdentifier,
            description: entry.description.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? "Installed app; no declared executable workflow.",
            supportStatus: supportStatus == .supported && capabilities.isEmpty ? .candidate : supportStatus,
            capabilities: capabilities,
            denyReason: entry.denyReason?.nilIfEmpty,
            metadata: entry.metadata
        )
    }

    private func sanitizedSupportStatus(_ entry: LocalAppFinderCatalogEntry) -> LocalAppFinderSupportStatus {
        if entry.supportStatus == .supported,
           entry.capabilities.contains(where: { capability in
            capability.controlProfiles.contains(where: Self.allowedControlProfiles.contains)
           }) {
            return .supported
        }
        if entry.supportStatus == .supported {
            return .candidate
        }
        return entry.supportStatus
    }

    private func sanitizedCapability(_ capability: LocalAppFinderCapability) -> LocalAppFinderCapability? {
        let id = capability.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = capability.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let profiles = capability.controlProfiles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter(Self.allowedControlProfiles.contains)
        guard !id.isEmpty, !summary.isEmpty, !profiles.isEmpty else { return nil }
        return LocalAppFinderCapability(
            id: id,
            summary: summary,
            controlProfiles: Array(Set(profiles)).sorted(),
            requiredEntities: capability.requiredEntities
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    private func baseMetadata(path: String?) -> [String: String] {
        var metadata = ["localItem.kind": LocalItemKind.application.rawValue]
        if let path = path?.nilIfEmpty {
            metadata["localItem.path"] = path
        }
        return metadata
    }

    private static func entry(
        matching id: String,
        in entries: [LocalAppFinderCatalogEntry]
    ) -> LocalAppFinderCatalogEntry? {
        entries.first {
            $0.appID == id || $0.bundleIdentifier == id
        }
    }

    private static func isOrderedBefore(
        lhs: LocalAppFinderCatalogEntry,
        rhs: LocalAppFinderCatalogEntry
    ) -> Bool {
        if lhs.appName == rhs.appName {
            return lhs.appID < rhs.appID
        }
        return lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
    }

    public static func defaultEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static let allowedControlProfiles: Set<String> = [
        "address_bar_submit",
        "new_document_text",
        "search_then_enter"
    ]
}

public final class LocalAppDynamicCatalogRefreshLoop: @unchecked Sendable {
    public var scanner: any LocalApplicationCatalogScanning
    public var profileStore: LocalAppFinderProfileStore
    public var profileGenerator: any LocalAppCatalogProfileGenerating
    public var refreshInterval: TimeInterval
    public var maxNewApplicationsPerRefresh: Int

    private let lock = NSLock()
    private var refreshTask: Task<Void, Never>?

    public init(
        scanner: any LocalApplicationCatalogScanning = MacInstalledApplicationCatalogScanner(),
        profileStore: LocalAppFinderProfileStore = .defaultStore,
        profileGenerator: any LocalAppCatalogProfileGenerating = NoOpLocalAppCatalogProfileGenerator(),
        refreshInterval: TimeInterval = 86_400,
        maxNewApplicationsPerRefresh: Int = 200
    ) {
        self.scanner = scanner
        self.profileStore = profileStore
        self.profileGenerator = profileGenerator
        self.refreshInterval = refreshInterval
        self.maxNewApplicationsPerRefresh = max(1, maxNewApplicationsPerRefresh)
    }

    deinit {
        stop()
    }

    public func start() {
        lock.lock()
        guard refreshTask == nil else {
            lock.unlock()
            return
        }
        refreshTask = Task.detached(priority: .utility) { [self] in
            await run()
        }
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        refreshTask?.cancel()
        refreshTask = nil
        lock.unlock()
    }

    public func refreshIfNeeded(
        now: Date = Date(),
        force: Bool = false
    ) async -> LocalAppCatalogRefreshResult {
        let state = profileStore.loadRefreshState()
        if !force,
           let lastRefreshAt = state.lastRefreshAt,
           now.timeIntervalSince(lastRefreshAt) < refreshInterval {
            let snapshotCount = profileStore.resolvedCatalogEntries().count
            return LocalAppCatalogRefreshResult(
                status: "skipped",
                installedApplicationCount: 0,
                newApplicationCount: 0,
                generatedProfileCount: 0,
                snapshotEntryCount: snapshotCount,
                metadata: ["reason": "refreshIntervalNotElapsed"]
            )
        }

        let installedApplications = scanner.installedApplications()
        let previouslySeenIDs = Set(state.seenApplicationIDs)
        let newApplications = installedApplications
            .filter { application in
                profileStore.profile(
                    appName: application.appName,
                    bundleIdentifier: application.bundleIdentifier
                ) == nil
                    && !previouslySeenIDs.contains(application.catalogID)
            }
            .prefix(maxNewApplicationsPerRefresh)

        let sourceTraceID = "local-app-catalog-refresh-\(UUID().uuidString)"
        let generation = await profileGenerator.generateProfiles(
            for: Array(newApplications),
            existingProfiles: profileStore.profileEntries(),
            sourceTraceID: sourceTraceID
        )
        try? profileStore.upsertGeneratedProfiles(generation.generatedEntries)

        let resolvedEntries = installedApplications.map(profileStore.entry(for:))
        try? profileStore.writeResolvedCatalogEntries(resolvedEntries)

        let profileKnownIDs = Set(installedApplications.compactMap { application -> String? in
            profileStore.profile(
                appName: application.appName,
                bundleIdentifier: application.bundleIdentifier
            ) == nil ? nil : application.catalogID
        })
        let seenIDs = previouslySeenIDs
            .union(profileKnownIDs)
            .union(generation.attemptedApplicationIDs)
        let updatedState = LocalAppCatalogRefreshState(
            lastRefreshAt: now,
            seenApplicationIDs: Array(seenIDs).sorted(),
            metadata: [
                "lastSourceTraceID": sourceTraceID,
                "installedApplicationCount": String(installedApplications.count),
                "newApplicationCount": String(newApplications.count),
                "generatedProfileCount": String(generation.generatedEntries.count)
            ].merging(generation.metadata) { current, _ in current }
        )
        try? profileStore.writeRefreshState(updatedState)

        return LocalAppCatalogRefreshResult(
            status: "refreshed",
            installedApplicationCount: installedApplications.count,
            newApplicationCount: newApplications.count,
            generatedProfileCount: generation.generatedEntries.count,
            snapshotEntryCount: resolvedEntries.count,
            metadata: updatedState.metadata
        )
    }

    private func run() async {
        while !Task.isCancelled {
            _ = await refreshIfNeeded()
            let seconds = max(60, refreshInterval)
            let nanoseconds = UInt64(seconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
