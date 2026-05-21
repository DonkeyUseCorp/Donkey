import AppKit
import DonkeyContracts
import Foundation

public struct LocalItemResolutionCacheEntry: Codable, Equatable, Sendable {
    public var id: String
    public var query: String
    public var normalizedQuery: String
    public var displayName: String
    public var normalizedDisplayName: String
    public var kind: String
    public var path: String?
    public var bundleIdentifier: String?
    public var isAvailable: Bool
    public var source: String
    public var match: String
    public var firstResolvedAt: String
    public var lastResolvedAt: String
    public var useCount: Int
    public var metadata: [String: String]
    public var searchText: String
}

public struct LocalItemResolutionCacheSearchResult: Equatable, Sendable {
    public var entry: LocalItemResolutionCacheEntry
    public var score: Int
}

public struct LocalItemResolutionCachePrewarmOptions: Sendable {
    public var applicationRoots: [URL]
    public var fileRoots: [URL]
    public var maxItemsPerRoot: Int

    public init(
        applicationRoots: [URL],
        fileRoots: [URL],
        maxItemsPerRoot: Int = 600
    ) {
        self.applicationRoots = applicationRoots
        self.fileRoots = fileRoots
        self.maxItemsPerRoot = max(0, maxItemsPerRoot)
    }

    public static func defaults() -> LocalItemResolutionCachePrewarmOptions {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        return LocalItemResolutionCachePrewarmOptions(
            applicationRoots: [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
                URL(fileURLWithPath: "/System/Applications", isDirectory: true),
                URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
                homeDirectory.appendingPathComponent("Applications", isDirectory: true)
            ],
            fileRoots: [
                homeDirectory.appendingPathComponent("Desktop", isDirectory: true),
                homeDirectory.appendingPathComponent("Documents", isDirectory: true),
                homeDirectory.appendingPathComponent("Downloads", isDirectory: true)
            ]
        )
    }
}

public final class LocalItemResolutionCache: @unchecked Sendable {
    public static let shared = LocalItemResolutionCache()

    public static var defaultStoreURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        return applicationSupport
            .appendingPathComponent("Donkey", isDirectory: true)
            .appendingPathComponent("LocalItemResolutionCache", isDirectory: true)
            .appendingPathComponent("local-item-cache.jsonl")
    }

    private let storeURL: URL
    private let lock = NSLock()
    private var entriesByID: [String: LocalItemResolutionCacheEntry]
    private var isPrewarming = false

    public init(storeURL: URL = LocalItemResolutionCache.defaultStoreURL) {
        self.storeURL = storeURL
        self.entriesByID = Self.loadEntries(from: storeURL)
    }

    public func prewarmDefaultLocalItemsInBackground(
        options: LocalItemResolutionCachePrewarmOptions = .defaults()
    ) {
        lock.lock()
        guard !isPrewarming else {
            lock.unlock()
            return
        }
        isPrewarming = true
        lock.unlock()

        Task.detached(priority: .utility) { [self] in
            prewarmDefaultLocalItems(options: options)
            finishPrewarming()
        }
    }

    public func prewarmDefaultLocalItems(
        options: LocalItemResolutionCachePrewarmOptions = .defaults()
    ) {
        guard options.maxItemsPerRoot > 0 else { return }

        var entries: [LocalItemResolutionCacheEntry] = []
        entries.append(contentsOf: prewarmEntries(
            roots: options.applicationRoots,
            allowedKinds: [.application],
            maxItemsPerRoot: options.maxItemsPerRoot
        ))
        entries.append(contentsOf: prewarmEntries(
            roots: options.fileRoots,
            allowedKinds: [.folder, .file, .other],
            maxItemsPerRoot: options.maxItemsPerRoot
        ))
        upsert(entries)
    }

    public func prewarmTaskDefinitions(_ definitions: [LocalAppTaskDefinition]) {
        upsert(definitions.map(Self.entry(taskDefinition:)))
    }

    public func taskDefinitions() -> [LocalAppTaskDefinition] {
        snapshotEntries()
            .filter { $0.kind == Self.taskDefinitionKind && $0.isAvailable }
            .compactMap(Self.taskDefinition(from:))
            .sorted { lhs, rhs in
                if lhs.taskType == rhs.taskType {
                    return lhs.targetApp.appName < rhs.targetApp.appName
                }
                return lhs.taskType < rhs.taskType
            }
    }

    public func record(
        availability: LocalAppAvailability,
        query: String,
        source: String
    ) {
        upsert([Self.entry(availability: availability, query: query, source: source)])
    }

    public func search(
        query: String,
        limit: Int = 5
    ) -> [LocalItemResolutionCacheSearchResult] {
        let lookupQuery = Self.lookupQuery(from: query)
        guard !lookupQuery.isEmpty, limit > 0 else { return [] }

        let snapshot = snapshotEntries()
        guard !snapshot.isEmpty else { return [] }

        let grepIDs = grepCandidateIDs(for: lookupQuery)
        let grepCandidates: [LocalItemResolutionCacheEntry]
        if let grepIDs, !grepIDs.isEmpty {
            grepCandidates = snapshot.filter { grepIDs.contains($0.id) }
        } else {
            grepCandidates = snapshot
        }

        let scored = Self.scoredResults(
            entries: grepCandidates,
            query: lookupQuery
        )
        if !scored.isEmpty {
            return Array(scored.prefix(limit))
        }

        return Array(Self.scoredResults(entries: snapshot, query: lookupQuery).prefix(limit))
    }

    public func contextSnippets(
        for query: String,
        limit: Int = 4
    ) -> [String] {
        search(query: query, limit: limit).map { result in
            let entry = result.entry
            let status = entry.isAvailable ? "available" : "missing"
            let path = entry.path.map { " path=\($0)" } ?? ""
            let bundleIdentifier = entry.bundleIdentifier.map { " bundleIdentifier=\($0)" } ?? ""
            let metadata = Self.snippetMetadata(entry.metadata)
            return "local_resolution_cache: query=\"\(entry.query)\" status=\(status) name=\"\(entry.displayName)\" kind=\(entry.kind)\(path)\(bundleIdentifier) source=\(entry.source) match=\(entry.match) score=\(result.score)\(metadata)"
        }
    }

    func cachedAvailability(
        named itemName: String,
        preferredKind: LocalItemKind?
    ) -> LocalAppAvailability? {
        let requestedName = LocalAppLookup.cleanedLookupName(itemName)
        guard !requestedName.isEmpty else { return nil }

        guard let result = search(query: requestedName, limit: 8).first(where: { result in
            guard result.entry.isAvailable else { return false }
            guard result.entry.kind != Self.taskDefinitionKind else { return false }
            if let preferredKind {
                return result.entry.kind == preferredKind.rawValue
            }
            return true
        }) else {
            return nil
        }

        let entry = result.entry
        let appURL = existingURL(for: entry)
        guard appURL != nil || entry.bundleIdentifier != nil else { return nil }

        var metadata = entry.metadata
        metadata["provider"] = "local-resolution-cache"
        metadata["cache.id"] = entry.id
        metadata["cache.source"] = entry.source
        metadata["cache.match"] = entry.match
        metadata["cache.score"] = String(result.score)
        metadata["requestedItemName"] = requestedName
        metadata["itemKind"] = entry.kind
        metadata["itemURL"] = appURL?.path ?? entry.path ?? ""
        metadata["bundleIdentifier"] = entry.bundleIdentifier ?? metadata["bundleIdentifier"] ?? ""
        metadata["match"] = "cache"

        var targetMetadata = [
            "localItem.kind": entry.kind,
            "localItem.path": appURL?.path ?? entry.path ?? ""
        ]
        if let defaultApplication = metadata["defaultApplication"], !defaultApplication.isEmpty {
            targetMetadata["localItem.defaultApplication"] = defaultApplication
        }

        markUsed(entryID: entry.id)

        return LocalAppAvailability(
            target: LocalAppTarget(
                appName: entry.displayName,
                bundleIdentifier: entry.bundleIdentifier,
                titleContains: entry.displayName,
                metadata: targetMetadata
            ),
            isInstalled: true,
            appURL: appURL,
            metadata: metadata
        )
    }

    private func prewarmEntries(
        roots: [URL],
        allowedKinds: Set<LocalItemKind>,
        maxItemsPerRoot: Int
    ) -> [LocalItemResolutionCacheEntry] {
        var entries: [LocalItemResolutionCacheEntry] = []
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            var rootCount = 0
            for case let itemURL as URL in enumerator {
                let kind = LocalItemKind(url: itemURL)
                guard allowedKinds.contains(kind) else { continue }

                entries.append(Self.entry(
                    url: itemURL,
                    query: Self.displayName(for: itemURL, kind: kind),
                    kind: kind,
                    source: "prewarm",
                    match: "prewarm",
                    metadata: [
                        "prewarm.root": root.path,
                        "parentDirectory": itemURL.deletingLastPathComponent().lastPathComponent,
                        "fileExtension": itemURL.pathExtension
                    ]
                ))
                rootCount += 1
                if rootCount >= maxItemsPerRoot { break }
            }
        }
        return entries
    }

    private func upsert(_ entries: [LocalItemResolutionCacheEntry]) {
        guard !entries.isEmpty else { return }

        lock.lock()
        for entry in entries {
            if var existing = entriesByID[entry.id] {
                existing.query = entry.query
                existing.normalizedQuery = entry.normalizedQuery
                existing.displayName = entry.displayName
                existing.normalizedDisplayName = entry.normalizedDisplayName
                existing.kind = entry.kind
                existing.path = entry.path
                existing.bundleIdentifier = entry.bundleIdentifier
                existing.isAvailable = entry.isAvailable
                existing.source = entry.source
                existing.match = entry.match
                existing.lastResolvedAt = entry.lastResolvedAt
                existing.useCount += max(1, entry.useCount)
                existing.metadata = existing.metadata.merging(entry.metadata) { _, new in new }
                existing.searchText = entry.searchText
                entriesByID[entry.id] = existing
            } else {
                entriesByID[entry.id] = entry
            }
        }
        persistLocked()
        lock.unlock()
    }

    private func markUsed(entryID: String) {
        lock.lock()
        if var entry = entriesByID[entryID] {
            entry.useCount += 1
            entry.lastResolvedAt = Self.timestamp()
            entriesByID[entryID] = entry
            persistLocked()
        }
        lock.unlock()
    }

    private func snapshotEntries() -> [LocalItemResolutionCacheEntry] {
        lock.lock()
        let entries = Array(entriesByID.values)
        lock.unlock()
        return entries
    }

    private func persistLocked() {
        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let text = try entriesByID.values
                .sorted { lhs, rhs in
                    if lhs.kind == rhs.kind {
                        return lhs.normalizedDisplayName < rhs.normalizedDisplayName
                    }
                    return lhs.kind < rhs.kind
                }
                .map { entry in
                    let data = try encoder.encode(entry)
                    return String(decoding: data, as: UTF8.self)
                }
                .joined(separator: "\n")
            try (text + "\n").write(to: storeURL, atomically: true, encoding: .utf8)
        } catch {
            return
        }
    }

    private func grepCandidateIDs(for query: String) -> Set<String>? {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return nil }

        let token = query
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .max(by: { $0.count < $1.count })
            ?? query
        guard !token.isEmpty else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        process.arguments = ["-i", "-F", token, storeURL.path]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        let decoder = JSONDecoder()
        return Set(text.split(whereSeparator: \.isNewline).compactMap { line in
            try? decoder.decode(LocalItemResolutionCacheEntry.self, from: Data(line.utf8)).id
        })
    }

    private func existingURL(for entry: LocalItemResolutionCacheEntry) -> URL? {
        if let path = entry.path {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        guard let bundleIdentifier = entry.bundleIdentifier else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    private func finishPrewarming() {
        lock.lock()
        isPrewarming = false
        lock.unlock()
    }

    private static func scoredResults(
        entries: [LocalItemResolutionCacheEntry],
        query: String
    ) -> [LocalItemResolutionCacheSearchResult] {
        let tokens = Set(query.split(separator: " ").map(String.init))
        return entries
            .compactMap { entry -> LocalItemResolutionCacheSearchResult? in
                guard let score = score(entry: entry, query: query, tokens: tokens) else {
                    return nil
                }
                return LocalItemResolutionCacheSearchResult(entry: entry, score: score)
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    if lhs.entry.isAvailable == rhs.entry.isAvailable {
                        return lhs.entry.useCount > rhs.entry.useCount
                    }
                    return lhs.entry.isAvailable && !rhs.entry.isAvailable
                }
                return lhs.score < rhs.score
            }
    }

    private static func score(
        entry: LocalItemResolutionCacheEntry,
        query: String,
        tokens: Set<String>
    ) -> Int? {
        let normalizedDisplayName = entry.normalizedDisplayName
        let normalizedQuery = entry.normalizedQuery
        let searchText = LocalAppLookup.normalized(entry.searchText)

        if normalizedDisplayName == query || normalizedQuery == query {
            return entry.isAvailable ? 0 : 30
        }
        if normalizedDisplayName.hasPrefix(query) {
            return entry.isAvailable ? 4 : 34
        }
        if normalizedDisplayName.contains(" \(query)") || normalizedDisplayName.contains(query) {
            return entry.isAvailable ? 8 : 38
        }

        let matchedTokenCount = tokens.filter { searchText.contains($0) }.count
        guard matchedTokenCount > 0 else { return nil }

        let missingPenalty = entry.isAvailable ? 0 : 40
        return missingPenalty + 60 - min(30, matchedTokenCount * 10) + max(0, normalizedDisplayName.count - query.count)
    }

    private static func entry(
        availability: LocalAppAvailability,
        query: String,
        source: String
    ) -> LocalItemResolutionCacheEntry {
        let kind = availability.metadata["itemKind"]
            ?? availability.target.metadata["localItem.kind"]
            ?? (availability.target.bundleIdentifier == nil ? "unknown" : LocalItemKind.application.rawValue)
        let path = availability.metadata["itemURL"]
            ?? availability.target.metadata["localItem.path"]
            ?? availability.appURL?.path
        let bundleIdentifier = availability.metadata["bundleIdentifier"]
            ?? availability.target.bundleIdentifier
        let displayName = availability.target.appName
        let match = availability.metadata["match"]
            ?? availability.metadata["reason"]
            ?? (availability.isInstalled ? "resolved" : "missing")

        var metadata = availability.metadata
        metadata["recordedQuery"] = query

        return LocalItemResolutionCacheEntry(
            id: id(
                kind: kind,
                path: path,
                bundleIdentifier: bundleIdentifier,
                displayName: displayName,
                query: query,
                isAvailable: availability.isInstalled
            ),
            query: query,
            normalizedQuery: lookupQuery(from: query),
            displayName: displayName,
            normalizedDisplayName: LocalAppLookup.normalized(displayName),
            kind: kind,
            path: path?.isEmpty == false ? path : nil,
            bundleIdentifier: bundleIdentifier?.isEmpty == false ? bundleIdentifier : nil,
            isAvailable: availability.isInstalled,
            source: source,
            match: match,
            firstResolvedAt: timestamp(),
            lastResolvedAt: timestamp(),
            useCount: 1,
            metadata: metadata,
            searchText: searchText(
                query: query,
                displayName: displayName,
                kind: kind,
                path: path,
                bundleIdentifier: bundleIdentifier,
                metadata: metadata
            )
        )
    }

    private static func entry(
        url: URL,
        query: String,
        kind: LocalItemKind,
        source: String,
        match: String,
        metadata: [String: String]
    ) -> LocalItemResolutionCacheEntry {
        let displayName = displayName(for: url, kind: kind)
        let bundleIdentifier = kind == .application ? Bundle(url: url)?.bundleIdentifier : nil
        var entryMetadata = metadata
        entryMetadata["itemKind"] = kind.rawValue
        entryMetadata["itemURL"] = url.path
        entryMetadata["bundleIdentifier"] = bundleIdentifier ?? ""

        return LocalItemResolutionCacheEntry(
            id: id(
                kind: kind.rawValue,
                path: url.path,
                bundleIdentifier: bundleIdentifier,
                displayName: displayName,
                query: query,
                isAvailable: true
            ),
            query: query,
            normalizedQuery: lookupQuery(from: query),
            displayName: displayName,
            normalizedDisplayName: LocalAppLookup.normalized(displayName),
            kind: kind.rawValue,
            path: url.path,
            bundleIdentifier: bundleIdentifier,
            isAvailable: true,
            source: source,
            match: match,
            firstResolvedAt: timestamp(),
            lastResolvedAt: timestamp(),
            useCount: 1,
            metadata: entryMetadata,
            searchText: searchText(
                query: query,
                displayName: displayName,
                kind: kind.rawValue,
                path: url.path,
                bundleIdentifier: bundleIdentifier,
                metadata: entryMetadata
            )
        )
    }

    private static func entry(taskDefinition definition: LocalAppTaskDefinition) -> LocalItemResolutionCacheEntry {
        let entityText = definition.entityRules
            .map(\.name)
            .joined(separator: " ")
        let workflowText = definition.workflowSteps
            .flatMap { step in [step.id, step.role.rawValue, step.summary] + step.metadata.flatMap { [$0.key, $0.value] } }
            .joined(separator: " ")
        var metadata = definition.metadata
        metadata["taskType"] = definition.taskType
        metadata["targetApp"] = definition.targetApp.appName
        metadata["bundleIdentifier"] = definition.targetApp.bundleIdentifier ?? ""
        metadata["entityNames"] = definition.entityRules.map(\.name).joined(separator: ",")
        metadata["observationStrategies"] = definition.observationStrategies.map(\.rawValue).joined(separator: ",")
        metadata["verificationEntityName"] = definition.verificationEntityName ?? ""

        if let encodedDefinition = encodedTaskDefinition(definition) {
            metadata[Self.taskDefinitionJSONMetadataKey] = encodedDefinition
        }

        return LocalItemResolutionCacheEntry(
            id: "task-definition:\(definition.taskType)",
            query: definition.taskType,
            normalizedQuery: lookupQuery(from: definition.taskType),
            displayName: Self.displayTitle(for: definition),
            normalizedDisplayName: LocalAppLookup.normalized(Self.displayTitle(for: definition)),
            kind: Self.taskDefinitionKind,
            path: nil,
            bundleIdentifier: definition.targetApp.bundleIdentifier,
            isAvailable: true,
            source: "task-definition-prewarm",
            match: "capability",
            firstResolvedAt: timestamp(),
            lastResolvedAt: timestamp(),
            useCount: 1,
            metadata: metadata,
            searchText: searchText(
                query: definition.taskType,
                displayName: Self.displayTitle(for: definition),
                kind: Self.taskDefinitionKind,
                path: nil,
                bundleIdentifier: definition.targetApp.bundleIdentifier,
                metadata: metadata.merging([
                    "taskText": "\(definition.taskType) \(entityText) \(workflowText)",
                    "targetAppTitle": definition.targetApp.titleContains ?? definition.targetApp.appName
                ]) { current, _ in current }
            )
        )
    }

    private static func encodedTaskDefinition(_ definition: LocalAppTaskDefinition) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(definition) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func taskDefinition(from entry: LocalItemResolutionCacheEntry) -> LocalAppTaskDefinition? {
        guard let encodedDefinition = entry.metadata[taskDefinitionJSONMetadataKey],
              let data = encodedDefinition.data(using: .utf8)
        else {
            return nil
        }
        return try? JSONDecoder().decode(LocalAppTaskDefinition.self, from: data)
    }

    private static func loadEntries(from storeURL: URL) -> [String: LocalItemResolutionCacheEntry] {
        guard let text = try? String(contentsOf: storeURL, encoding: .utf8) else { return [:] }

        let decoder = JSONDecoder()
        let entries = text
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                try? decoder.decode(LocalItemResolutionCacheEntry.self, from: Data(line.utf8))
            }
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    }

    private static func id(
        kind: String,
        path: String?,
        bundleIdentifier: String?,
        displayName: String,
        query: String,
        isAvailable: Bool
    ) -> String {
        if !isAvailable {
            return "missing:\(lookupQuery(from: query))"
        }
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            return "\(kind):bundle:\(bundleIdentifier)"
        }
        if let path, !path.isEmpty {
            return "\(kind):path:\(path)"
        }
        return "\(kind):name:\(LocalAppLookup.normalized(displayName))"
    }

    private static func searchText(
        query: String,
        displayName: String,
        kind: String,
        path: String?,
        bundleIdentifier: String?,
        metadata: [String: String]
    ) -> String {
        (
            [
                query,
                displayName,
                LocalAppLookup.normalized(displayName),
                kind,
                path ?? "",
                bundleIdentifier ?? ""
            ] + metadata
                .filter { $0.key != Self.taskDefinitionJSONMetadataKey }
                .sorted { $0.key < $1.key }
                .flatMap { [$0.key, $0.value] }
        )
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    private static func snippetMetadata(_ metadata: [String: String]) -> String {
        let allowedKeys = [
            "taskType",
            "targetApp",
            "itemKind",
            "defaultApplication",
            "entityNames",
            "verificationMode",
            "automationBackend",
            "appleScript.action",
            "screenshotFallback"
        ]
        let pairs = allowedKeys.compactMap { key -> String? in
            guard let value = metadata[key], !value.isEmpty else { return nil }
            return "\(key)=\(value)"
        }
        guard !pairs.isEmpty else { return "" }
        return " metadata={\(pairs.joined(separator: ","))}"
    }

    private static func lookupQuery(from query: String) -> String {
        LocalAppLookup.cleanedLookupName(query)
    }

    private static let taskDefinitionKind = "taskDefinition"
    private static let taskDefinitionJSONMetadataKey = "taskDefinitionJSON"

    private static func displayName(for url: URL, kind: LocalItemKind) -> String {
        if kind == .application,
           let bundle = Bundle(url: url) {
            return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
        }

        return url.lastPathComponent
    }

    private static func displayTitle(for definition: LocalAppTaskDefinition) -> String {
        if let displayTitle = definition.metadata["displayTitle"], !displayTitle.isEmpty {
            return displayTitle
        }
        return definition.taskType
            .split(separator: "_")
            .map { word in word.prefix(1).uppercased() + word.dropFirst() }
            .joined(separator: " ")
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
